package Plack::Middleware::WOVN;
use strict;
use warnings;
use utf8;
use parent 'Plack::Middleware';

our $VERSION = '0.06';

require bytes;

use HTML::HTML5::Parser;
use Mojo::URL;
use Plack::Util;
use Plack::Util::Accessor qw( settings );
use URI::Escape;
use XML::LibXML;

use Plack::Middleware::WOVN::Headers;
use Plack::Middleware::WOVN::Lang;
use Plack::Middleware::WOVN::Store;

our $STORE;

sub prepare_app {
    my $self = shift;
    $STORE = Plack::Middleware::WOVN::Store->new(
        { settings => $self->settings } );
}

sub call {
    my ( $self, $env ) = @_;

    unless ( $STORE->is_valid_settings ) {
        return $self->app->($env);
    }

    my $headers
        = Plack::Middleware::WOVN::Headers->new( $env, $STORE->settings );
    if (   $STORE->settings->{test_mode}
        && $STORE->settings->{test_url} ne $headers->url )
    {
        return $self->app->($env);
    }

    if ( $headers->path_lang eq $STORE->settings->{default_lang} ) {
        my $redirect_headers
            = $headers->redirect( $STORE->settings->{default_lang} );
        return [ 307, [%$redirect_headers], [''] ];
    }
    my $lang = $headers->lang_code;

    my $res = $self->app->( $headers->request_out );
    Plack::Util::response_cb(
        $res,
        sub {
            my $res = shift;

            sub {
                my $body_chunk  = shift or return;
                my $status      = $res->[0];
                my $res_headers = $res->[1];

                if ((   Plack::Util::header_get( $res_headers,
                            'Content-Type' )
                        || ''
                    ) =~ /html/
                    )
                {
                    my $values = $STORE->get_values( $headers->redis_url );
                    my $url    = {
                        protocol => $headers->protocol,
                        host     => $headers->host,
                        pathname => $headers->pathname,
                    };
                    $body_chunk
                        = switch_lang( $body_chunk, $values, $url, $lang,
                        $headers )
                        unless $status =~ /^1|302/;
                }

                Plack::Util::header_set( $res_headers, 'Content-Length',
                    bytes::length $body_chunk );

                $body_chunk;
            };
        }
    );
}

sub add_lang_code {
    my ( $href, $pattern, $lang, $headers ) = @_;
    return $href if $href =~ /^(#.*)?$/;

    my $new_href = $href;
    my $lc_lang  = lc $lang;

    if ( $href && lc($href) =~ /^(https?:)?\/\// ) {
        my $uri = eval { Mojo::URL->new($href) } or return $new_href;

        if ( lc $uri->host eq lc $headers->host ) {
            if ( $pattern eq 'subdomain' ) {
                my $sub_d = $href =~ /\/\/([^\.]*)\./ ? $1 : '';
                my $sub_code
                    = Plack::Middleware::WOVN::Lang->get_code($sub_d);
                if ( $sub_code && lc $sub_code eq $lc_lang ) {
                    $new_href =~ s/$lang/$lc_lang/i;
                }
                else {
                    $new_href =~ s/(\/\/)([^\.]*)/$1$lc_lang\.$2/;
                }
            }
            elsif ( $pattern eq 'query' ) {
                if ( $href =~ /\?/ ) {
                    $new_href = "$href&wovn=$lang";
                }
                else {
                    $new_href = "$href?wovn=$lang";
                }
            }
            else {
                $new_href =~ s/([^\.]*\.[^\/]*)(\/|$)/$1$lang/;
            }
        }
    }
    elsif ($href) {
        if ( $pattern eq 'subdomain' ) {
            my $lang_url
                = $headers->protocol . '://'
                . $lc_lang . '.'
                . $headers->host;
            my $current_dir = $headers->pathname;
            $current_dir =~ s/[^\/]*\.[^\.]{2,6}$//;
            if ( $href =~ /^\.\..*$/ ) {
                $new_href =~ s/^(\.\.\/)+//;
                $new_href = $lang_url . '/' . $new_href;
            }
            elsif ( $href =~ /^\..*$/ ) {
                $new_href =~ s/^(\.\/)+//;
                $new_href = $lang_url . $current_dir . '/' . $new_href;
            }
            elsif ( $href =~ /^\/.*$/ ) {
                $new_href = $lang_url . $href;
            }
            else {
                $new_href = $lang_url . $current_dir . '/' . $href;
            }
        }
        elsif ( $pattern eq 'query' ) {
            if ( $href =~ /\?/ ) {
                $new_href = "$href&wovn=$lang";
            }
            else {
                $new_href = "$href?wovn=$lang";
            }
        }
        else {
            if ( $href =~ /^\// ) {
                $new_href = '/' . $lang . $href;
            }
            else {
                my $current_dir = $headers->pathname;
                $current_dir =~ s/[^\/]*\.[^\.]{2,6}$//;
                $new_href = '/' . $lang . $current_dir . $href;
            }
        }
    }

    $new_href;
}

sub check_wovn_ignore {
    my $node = shift;
    if ( !$node->isTextNode ) {
        if ( defined $node->attr('wovn-ignore') ) {
            $node->attr( 'wovn-ignore', '' )
                if $node->attr('wovn-ignore') eq 'wovn-ignore';
            return 1;
        }
        elsif ( $node->tag eq 'html' ) {
            return 0;
        }
    }
    if ( !$node->getParentNode ) {
        return 0;
    }
    check_wovn_ignore( $node->getParentNode );
}

sub switch_lang {
    my ( $body, $values, $url, $lang, $headers ) = @_;
    $lang ||= $STORE->settings->{'default_lang'};
    $lang = Plack::Middleware::WOVN::Lang->get_code($lang);
    my $text_index     = $values->{text_vals}      || {};
    my $src_index      = $values->{img_vals}       || {};
    my $img_src_prefix = $values->{img_src_prefix} || '';
    my $ignore_all     = 0;
    my $string_index   = {};

    my $tree = HTML::HTML5::Parser->load_html($body);

    if ( $ignore_all || $tree->exists('//html[@wovn-ignore]') ) {
        $ignore_all = 1;
        $body =~ s/href="([^"]*)"/"href=\"".uri_unescape($1)."\""/eg;
        return $body;
    }

    if ( $lang ne $STORE->settings->{default_lang} ) {
        for my $node ( $tree->findnodes('//a') ) {
            next if check_wovn_ignore($node);
            my $href = $node->attr('href');
            my $new_href
                = add_lang_code( $href, $STORE->settings->{url_pattern},
                $lang, $headers );
            $node->attr( 'href', $new_href );
        }
    }

    for my $node ( $tree->findnodes('//text()') ) {
        next if check_wovn_ignore($node);
        my $node_text = $node->getValue;
        $node_text =~ s/^\s+|\s+$//g;
        if (   $text_index->{$node_text}
            && $text_index->{$node_text}{$lang}
            && @{ $text_index->{$node_text}{$lang} } )
        {
            my $data    = $text_index->{$node_text}{$lang}[0]{data};
            my $content = $node->getValue;
            $content =~ s/^(\s*)[\S\s]*(\s*)$/$1$data$2/g;
            if ( $node->getParentNode ) {
                $node->getParentNode->delete_content;
                $node->getParentNode->push_content($content);
            }
            else {
                # Some nodes do not have parent node,
                # whose content cannot be updated.
                $node->{_content} = $data;
            }
        }
    }

    for my $node ( $tree->findnodes('//meta') ) {
        next if check_wovn_ignore($node);
        next
            if ( $node->attr('name') || $node->attr('property') || '' )
            !~ /^(description|title|og:title|og:description|twitter:title|twitter:description)$/;

        my $node_content = $node->attr('content');
        $node_content =~ s/^\s+\|\s+$//g;
        if (   $text_index->{$node_content}
            && $text_index->{$node_content}{$lang}
            && @{ $text_index->{$node_content}{$lang} } )
        {
            my $data    = $text_index->{$node_content}{$lang}[0]{data};
            my $content = $node->attr('content');
            $content =~ s/^(\s*)[\S\s]*(\s*)$/$1$data$2/g;
            $node->attr( 'content', $content );
        }
    }

    for my $node ( $tree->findnodes('//img') ) {
        next if check_wovn_ignore($node);
        if ( lc( $node->as_HTML( '', undef, {} ) ) =~ /src=['"]([^'"]*)['"]/ )
        {
            my $src = $1;
            if ( $src !~ /:\/\// ) {
                if ( $src =~ /^\// ) {
                    $src = $url->{protocol} . '://' . $url->{host} . $src;
                }
                else {
                    $src
                        = $url->{protocol} . '://'
                        . $url->{host}
                        . $url->{path}
                        . $src;
                }
            }

            if (   $src_index->{$src}
                && $src_index->{$src}{$lang}
                && @{ $src_index->{$src}{$lang} } )
            {
                $node->attr( 'src',
                    $img_src_prefix . $src_index->{$src}{$lang}[0]{data} );
            }
        }
        if ( my $alt = $node->attr('alt') ) {
            $alt =~ s/^\s+|\s+$//g;
            if (   $text_index->{$alt}
                && $text_index->{$alt}{$lang}
                && @{ $text_index->{$alt}{$lang} } )
            {
                my $data = $text_index->{$alt}{$lang}[0]{data};
                $alt =~ s/^(\s*)[\S\s]*(\s*)$/$1$data$2/g;
                $node->attr( 'alt', $alt );
            }
        }
    }

    for my $node ( $tree->findnodes('//script') ) {
        if (   $node->attr('src')
            && $node->attr('src') =~ /\/\/j.(dev-)?wovn.io(:3000)?\// )
        {
            $node->delete;
        }
    }

    my ($parent_node) = $tree->findnodes('//head');
    ($parent_node) = $tree->findnodes('//body') unless $parent_node;
    ($parent_node) = $tree->findnodes('//html') unless $parent_node;

    {
        my $insert_node = XML::LibXML::Element->new('script');
        $insert_node->attr( 'src',   '//j.wovn.io/1' );
        $insert_node->attr( 'async', 'true' );
        my $data_wovnio
            = 'key='
            . $STORE->settings->{user_token}
            . '&backend=true&currentLang='
            . $lang
            . '&defaultLang='
            . $STORE->settings->{default_lang}
            . '&urlPattern='
            . $STORE->settings->{url_pattern}
            . '&version='
            . $VERSION;
        $insert_node->attr( 'data-wovnio', $data_wovnio );
        $insert_node->content(' ');
        $parent_node->unshift_content($insert_node);
    }

    for my $l ( get_langs($values) ) {
        my $insert_node = XML::LibXML::Element->new('link');
        $insert_node->attr( 'rel',      'alternate' );
        $insert_node->attr( 'hreflang', $l );
        $insert_node->attr( 'href',     $headers->redirect_location($l) );
        $parent_node->push_content($insert_node);
    }

    my ($html) = $tree->findnodes('//html');
    ($html) = $tree->findnodes('//HTML') unless $html;
    $html->attr( 'lang', $lang ) if $html;

    my $new_body = $tree->as_HTML( '', undef, {} );
    $new_body =~ s/href="([^"]*)"/'href="'.uri_unescape($1).'"'/eg;

    $tree->delete;

    $new_body;
}

sub get_langs {
    my $values = shift;
    my %langs;
    my %merged
        = ( %{ $values->{text_vals} || {} }, %{ $values->{img_vals} || {} } );
    for my $index ( values %merged ) {
        for my $key ( keys %{ $index || {} } ) {
            $langs{$key} = 1;
        }
    }
    keys %langs;
}

1;

__END__

=encoding utf-8

=head1 NAME

Plack::Middleware::WOVN - Translates PSGI application by using WOVN.io.

=head1 SYNOPSYS

  use Plack::Builder;

  builder {
    'WOVN',
      settings => {
        user_token => 'token',
        secret_key => 'sectet',
      };
    $app;
  };

=head1 DESCRIPTION

This is a Plack Middleware component for translating PSGI application by using WOVN.io.
Before using this middleware, you must sign up and configure WOVN.io.

=head1 SETTINGS

=head2 user_token

User token of your WOVN.io account. This value is required.

=head2 secret_key

This value will be used in the future. But this value is required.

=head2 url_pattern

URL rewriting pattern of translated page.

=over 4

=item * path (default)

  original: http://example.com/

  translated: http://example.com/ja/

=item * subdomain

  original: http://example.com/

  translated: http://ja.exmple.com/

=item * query

  original: http://example.com/

  translated: http://example.com/?wovn=ja

=back

=head2 url_pattern_reg

This value is coufigured by url_pattern. You don't have to configure this value.

=head2 query

Filters query parameters when rewriting URL. Default values is []. (Do not filter query)

=head2 api_url

URL of WOVN.io API. Default value is "https://api.wovn.io/v0/values".

=head2 default_lang

Default language of web application. Default value is "en".

=head2 supported_langs

This value will be used in the future. Default value is ["en"].

=head2 test_mode

When "on" or "1" is set to "test_mode", this middleware translates only the page whose url is "test_url".
Default value is "0".

=head2 test_url

Default value is not set.

=head1 LICENSE

Copyright (C) 2016 by Masahiro Iuchi.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 AUTHOR

Masahiro Iuchi

=cut

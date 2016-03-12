## -*- mode: perl; coding: utf-8 -*-

requires 'perl', '5.010';

requires 'Plack::Middleware';
requires 'parent';

requires 'Class::Accessor::Fast';
requires 'HTML::Element';
requires 'HTML::TreeBuilder::XPath';
requires 'JSON';
requires 'LWP::Protocol::https';
requires 'LWP::UserAgent';
requires 'Mojo::URL';
requires 'Plack::Util';
requires 'Plack::Util::Accessor';
requires 'URI::Escape';

on test => sub {
    requires 'Test::More', '0.98';
    requires 'URI';
};


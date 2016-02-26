
# NAME

Plack::Middleware::WOVN - Translates PSGI application by using WOVN.io.

# SYNOPSYS

    use Plack::Builder;

    builder {
      'WOVN',
        settings => {
          user_token => 'token',
          secret_key => 'sectet',
        };
      $app;
    };

# DESCRIPTION

This is a Plack Middleware component for translating PSGI application by using WOVN.io.
Before using this middleware, you must sign up and configure WOVN.io.

# SETTINGS

## user\_token

User token of your WOVN.io account. This value is required.

## secret\_key

This value will be used in the future. But this value is required.

## url\_pattern

URL rewriting pattern of translated page.

- path (default)

        original: http://example.com/

        translated: http://example.com/ja/

- subdomain

        original: http://example.com/

        translated: http://ja.exmple.com/

- query

        original: http://example.com/

        translated: http://example.com/?wovn=ja

## url\_pattern\_reg

This value is coufigured by url\_pattern. You don't have to configure this value.

## query

Filters query parameters when rewriting URL. Default values is \[\]. (Do not filter query)

## api\_url

URL of WOVN.io API. Default value is "https://api.wovn.io/v0/values".

## default\_lang

Default language of web application. Default value is "en".

## supported\_langs

This value will be used in the future. Default value is \["en"\].

## test\_mode

When "on" or "1" is set to "test\_mode", this middleware translates only the page whose url is "test\_url".
Default value is "0".

## test\_url

Default value is not set.

# LICENSE

Copyright (C) 2016 by Masahiro Iuchi.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

# AUTHOR

Masahiro Iuchi

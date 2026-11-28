# Changelog

What each release changed for you, newest first. Each line is a commit's summary, linked to its full description and diff. Releases before 1.6.1 are described by their release commits.

## 1.24.0 - 2026-11-28

### Features

- Middleware: allow_bots sends only a crawler's User-Agent, at most four an address ([`5972649`](https://github.com/internetdata/sdk-erlang/commit/59726490fca04bf932fd91f22148d98ad35a1e9a))

### Fixes

- Middleware: a condition on the verdict is no plan gap for a request that sent no agent ([`2dc1a1e`](https://github.com/internetdata/sdk-erlang/commit/2dc1a1e01e39edd971d64ee92d15fc480f9bb39c))
- Middleware: a bogon's answer reports no missing member ([`d9fb0b4`](https://github.com/internetdata/sdk-erlang/commit/d9fb0b463b71723cd614c22e32dc50d89f010b0c))
- Spec 2026.11.27: the free plan's trial is a window, and no comment names a figure ([`ecb7007`](https://github.com/internetdata/sdk-erlang/commit/ecb700741c01a72d8460f91b54f2a0f3c3297b4b))

## 1.23.0 - 2026-11-27

### Fixes

- Read a keyless answer without the AS's type ([`4b63a90`](https://github.com/internetdata/sdk-erlang/commit/4b63a9043e6c0dd6efb48bd142dfbda61fee463c))

## 1.22.0 - 2026-11-26

### Fixes

- Read a keyless answer without the bot, carrier, satellite and service flags ([`dffe008`](https://github.com/internetdata/sdk-erlang/commit/dffe008d55e528fa9b6cf77f3ab93778f9a2b077))

## 1.21.0 - 2026-11-25

### Features

- Send the user agent of the request you are deciding on, and let a verified crawler through the middleware ([`b4924bf`](https://github.com/internetdata/sdk-erlang/commit/b4924bfd41ec72d4fa0044bb6338237bae2842c9))

### Fixes

- Refuse an option no call could use where it is given: the cache's, a downloads limit, the middleware's ([`cca87f9`](https://github.com/internetdata/sdk-erlang/commit/cca87f9412e3ac70027f5ed7f372db6bf1904420))
- Re-pin the spec to 2026.11.25, and test an upper bound on a member the plan lacks ([`b74e54e`](https://github.com/internetdata/sdk-erlang/commit/b74e54e49a088c6780e0161a7eca5f4235177313))

## 1.20.0 - 2026-11-24

### Features

- Match a condition on a list member when any element matches ([`a5b6068`](https://github.com/internetdata/sdk-erlang/commit/a5b60681569e8936ee359e31aa1ab241b1751433))

### Fixes

- Re-pin the spec to 2026.11.23: refuse a seen day that is no date ([`394fce8`](https://github.com/internetdata/sdk-erlang/commit/394fce8892d6a7e9f3a4a5a837a3e47e40368e23))

## 1.19.1 - 2026-11-23

### Fixes

- Refuse a lookup answer without is_bot, which every answer carries ([`22905e0`](https://github.com/internetdata/sdk-erlang/commit/22905e00c92ad458a6524eb61ebd42320d9dc0e4))
- Re-pin the spec to 2026.11.22: a bot's provider for an unverified address ([`2086769`](https://github.com/internetdata/sdk-erlang/commit/20867696b28f7ee3bf92c9a0a837c91f6b2000bc))

## 1.19.0 - 2026-11-22

### Features

- Read is_bot on every plan, and whose bot uses the address on a paid plan ([`4179215`](https://github.com/internetdata/sdk-erlang/commit/41792158c0aeb6dc95d622313d31fd57fe2ff5e0))

## 1.18.1 - 2026-11-21

### Fixes

- Re-pin the spec to 2026.11.20 as republished: 64-bit AS numbers, and the AS's country and RPKI status required ([`9e486d6`](https://github.com/internetdata/sdk-erlang/commit/9e486d65af277e12fd93c564f24d8480baaa8f3c))

## 1.18.0 - 2026-11-20

### Features

- Read a paid domain answer's hosting, co-hosted domains, home page, redirects and backlinks ([`9374a85`](https://github.com/internetdata/sdk-erlang/commit/9374a8581a1358654170caecdc3d0930688d49b3))

## 1.17.3 - 2026-11-20

### Fixes

- Re-pin the spec to 2026.11.20: the free trial without a count or period ([`4b2a070`](https://github.com/internetdata/sdk-erlang/commit/4b2a070ed65fe6728d5f759940fe79f4ba1a9f86))

## 1.17.2 - 2026-11-19

### Fixes

- Cache a spent trial's or a reached cap's answer for a minute at most ([`b6f9e08`](https://github.com/internetdata/sdk-erlang/commit/b6f9e08680ff76a6274942f8a7f52be073122e35))

## 1.17.1 - 2026-11-18

### Fixes

- Re-pin the spec to 2026.11.17 as republished: KEY_OVER_HTTP on the account 403 ([`5157372`](https://github.com/internetdata/sdk-erlang/commit/51573728a2a0aed6dc0779b2ac98e01f98e937e9))

## 1.17.0 - 2026-11-17

### Features

- Read cap_reached on a paid answer past its overage cap ([`37d4199`](https://github.com/internetdata/sdk-erlang/commit/37d41994da747f7b5a72ef74303dd32560b71d92))

## 1.16.0 - 2026-11-16

### Features

- Read an AS's rank, neighbors and hosted domains, and the plan's name ([`0ac2da3`](https://github.com/internetdata/sdk-erlang/commit/0ac2da3c82eb336098943f5d15afe04b0dcab518))

## 1.15.0 - 2026-11-15

### Features

- Release: stop before the GitHub Release when hex.pm only stages the publish ([`54f7268`](https://github.com/internetdata/sdk-erlang/commit/54f72685e3ce028926a26d084f8f06abfa2fe0a9))
- Read hosted_domains' 10 most popular domains ([`c0c52cf`](https://github.com/internetdata/sdk-erlang/commit/c0c52cfc062e8b47c819b6af64db3b9e144d785f))

## 1.14.1 - 2026-11-14

### Fixes

- Re-pin the spec to 2026.11.13 as republished: the ip.lookup scope 403 ([`3f2b058`](https://github.com/internetdata/sdk-erlang/commit/3f2b0584043d802878db4059c1517e82dbe41551))

## 1.14.0 - 2026-11-14

### Features

- Add the framework middleware core ([`9c32d0d`](https://github.com/internetdata/sdk-erlang/commit/9c32d0d4ad4668b9ce380f96c708f2c1e2bb5f5b))

## 1.13.0 - 2026-11-13

### Features

- Default to https://api.internetdata.io, signing in at its apex ([`f3f031d`](https://github.com/internetdata/sdk-erlang/commit/f3f031d3cfe762a48a5e3fba4e7dcecab05dac51))
- Look up addresses, ASes and domains: lookup, lookup_batch, lookup_asn and lookup_domain ([`3868d8b`](https://github.com/internetdata/sdk-erlang/commit/3868d8b062a1e60e3531f6da9bdf1c1131a30e7b))

## 1.12.1 - 2026-11-09

### Fixes

- Re-pin the spec to 2026.11.08: the token and revoke descriptions ([`9469e09`](https://github.com/internetdata/sdk-erlang/commit/9469e09293c5fb37e2123986663cc792a1a29ab8))

## 1.12.0 - 2026-11-07

### Features

- Download a named build: database_download_url/4, database_download/5 and database_download_bytes/4 take build ([`564c7ce`](https://github.com/internetdata/sdk-erlang/commit/564c7ce63a0edc88d384fe633c39d5b0696e3f30))

## 1.11.6 - 2026-11-06

### Fixes

- Re-pin the spec to 2026.11.05: the download's build parameter ([`a99cb55`](https://github.com/internetdata/sdk-erlang/commit/a99cb5594e20e4292bbef8af1d7e702e9837271f))

## 1.11.5 - 2026-11-03

### Fixes

- Re-pin the spec to 2026.11.02: ID and IDs in its descriptions ([`3192b48`](https://github.com/internetdata/sdk-erlang/commit/3192b4879adf63fb661e9a6f85db18958bdfa5c4))
- Write ID and IDs in prose, never id or ids ([`f739791`](https://github.com/internetdata/sdk-erlang/commit/f739791a281520a595c1e37a531d6ec0e754738b))

## 1.11.4 - 2026-10-30

### Fixes

- Refuse a checksum answer without its ID or format ([`8505274`](https://github.com/internetdata/sdk-erlang/commit/85052742eb233cb4931aee1b8998367d279dd35c))

## 1.11.3 - 2026-10-29

### Fixes

- Refuse a date or date-time member that is not RFC 3339 ([`9e50fd4`](https://github.com/internetdata/sdk-erlang/commit/9e50fd44193117ac2143ccd3e868921330f17e8d))

## 1.11.2 - 2026-10-21

### Fixes

- Re-pin the spec to 2026.10.21: a 403 for a refused address ([`d282549`](https://github.com/internetdata/sdk-erlang/commit/d28254979e291b9bd69d8786a867ae78ee5eccb9))

## 1.11.1 - 2026-10-18

### Fixes

- Re-pin the spec to 2026.10.18: client_id_issued_at is int64 ([`60789c1`](https://github.com/internetdata/sdk-erlang/commit/60789c1db68185a8556d897e7a9f633e9133a171))

## 1.11.0 - 2026-10-18

### Features

- Add oauth_register, for RFC 7591 dynamic client registration ([`613d6d8`](https://github.com/internetdata/sdk-erlang/commit/613d6d843f85ea717983fe2d75e5c9d96d7352b1))

## 1.10.2 - 2026-10-18

### Fixes

- Take false and nil as no API key ([`604ff01`](https://github.com/internetdata/sdk-erlang/commit/604ff013b39dab2f8ac3623bbf187827f5d71d9d))

## 1.10.1 - 2026-10-17

### Fixes

- Refuse a database answer whose member has the wrong type ([`6ddf406`](https://github.com/internetdata/sdk-erlang/commit/6ddf406ec9e0cde0a263af2e67f458c78acc1464))

## 1.10.0 - 2026-10-17

### Features

- Re-pin the spec to 2026.10.16: dynamic client registration ([`ee0654a`](https://github.com/internetdata/sdk-erlang/commit/ee0654afbefb82dfcf16d334f2ca28f4728a1293))

## 1.9.5 - 2026-10-16

### Fixes

- Re-pin the spec to 2026.10.15: three descriptions in US spelling ([`a846cfb`](https://github.com/internetdata/sdk-erlang/commit/a846cfbdf1901f033ff1b0e3295b01342f46230c))

## 1.9.4 - 2026-10-15

### Fixes

- Retry an unreadable answer to OAuth discovery and device authorization ([`afd627d`](https://github.com/internetdata/sdk-erlang/commit/afd627d59c4866cfc7b4986f3bdfa8e0ca0ab3a5))

## 1.9.3 - 2026-10-13

### Fixes

- Re-pin the spec to 2026.10.13: Open databases come with a license ([`f629df2`](https://github.com/internetdata/sdk-erlang/commit/f629df22e42d6b40dd0c66087c93a369a96c7054))

## 1.9.2 - 2026-10-11

### Fixes

- Read Retry-After as digits or an RFC 9110 date in GMT, never crashing ([`55295d2`](https://github.com/internetdata/sdk-erlang/commit/55295d2efe88a5b34a2c92759d223cc5b7173cca))
- Trim the key and refuse a control character in it; retry an unreadable 2xx ([`6e7bd62`](https://github.com/internetdata/sdk-erlang/commit/6e7bd620efe62dbc36357d60a06df1efa191ebe6))

## 1.9.1 - 2026-10-10

### Fixes

- Re-pin the spec to 2026.10.09: rotating a key needs apikeys.reveal ([`48f45af`](https://github.com/internetdata/sdk-erlang/commit/48f45afcde9282a3480580ce52c8b02cc63c2fff))

## 1.9.0 - 2026-10-09

### Features

- Re-pin the spec to 2026.10.08, adding the Open databases' open flag ([`e42f80d`](https://github.com/internetdata/sdk-erlang/commit/e42f80db1dbed6b877cff0e26a40f1a1ecdca5a3))

## 1.8.2 - 2026-10-05

### Fixes

- Hand a 503 to the client's retries at once on OTP 28.4 and later ([`bdcb291`](https://github.com/internetdata/sdk-erlang/commit/bdcb29190b3cd105ec1e668e1af87968b741c097))

## 1.8.1 - 2026-10-04

### Fixes

- Re-pin the spec to 2026.10.03: metadata needs no license ([`09e9e8d`](https://github.com/internetdata/sdk-erlang/commit/09e9e8d0c38e2c991dc47828ccbcab5943428612))

## 1.8.0 - 2026-09-30

### Features

- Add the authorization code sign-in, with PKCE ([`9383997`](https://github.com/internetdata/sdk-erlang/commit/9383997a59d81cb0c76d080eb6e2091be000541b))

## 1.7.0 - 2026-09-27

### Features

- Re-pin the spec to 2026.09.26, adding its evaluation-sample fields ([`4f8c7a6`](https://github.com/internetdata/sdk-erlang/commit/4f8c7a6ffd7a5a723af14e9f35a082b0a3838783))

## 1.6.1 - 2026-09-23

### Fixes

- Drop every trailing slash, and refuse impossible timeouts ([`6ce736d`](https://github.com/internetdata/sdk-erlang/commit/6ce736d6c0456a4ca13f3489743773dafe9e37d2))

# Changelog

What each release changed for you, newest first. Each line is a commit's summary, linked to its full description and diff. Releases before 1.6.1 are described by their release commits.

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

# [<img src="https://s3.internetdata.io/internetdata-public/brand/mark.svg" alt="InternetData" width="24"/>](https://internetdata.io/) InternetData Erlang Client Library

[![hex.pm](https://img.shields.io/hexpm/v/internetdata.svg)](https://hex.pm/packages/internetdata)
[![license](https://img.shields.io/hexpm/l/internetdata.svg)](LICENSE)

The official Erlang client library for the [InternetData](https://internetdata.io) database API.

The library helps you browse the datasets your organization licenses and download them: IP, ASN and domain data, published as gzipped CSV and MMDB.

## Getting Started

```erlang
%% rebar.config
{deps, [internetdata]}.
```

Requires Erlang/OTP 27 or newer. There are no runtime dependencies: everything the client needs is in OTP. From Elixir, add `{:internetdata, "~> 1.0"}` to your `mix.exs` deps and call it as `:internetdata`.

## Usage

Every endpoint is authenticated, so a client needs an API key. Create one in the [console](https://app.internetdata.io) with the `db.download` scope; keys are default-deny, so an existing key does not gain database access until that scope is added to it.

```erlang
Client = internetdata:new(#{api_key => <<"your-api-key">>}),

{ok, Databases} = internetdata:database_list(Client),
[maps:get(base, D) || D <- Databases].   % [<<"bogon_ip">>, <<"vpn_ip">>, ...]
```

Every call answers `{ok, Term}` or `{error, Error}`. The client is a plain term holding no process and no connection of its own, so there is nothing to close and nothing to keep alive.

### The catalog

`database_list/1` returns every dataset FAMILY your organization may see, with your license beside each one:

```erlang
{ok, Databases} = internetdata:database_list(Client),

[begin
     io:format("~s (~s): ~s~n", [maps:get(base, D), maps:get(standing, D), maps:get(name, D)]),
     [io:format("  ~s ~p~n", [maps:get(id, V), maps:get(formats, V)])
      || V <- maps:get(versions, D)]
 end || D <- Databases].
```

`standing` is `<<"licensed">>` for a live grant, `<<"expired">>` for one whose term has ended, and `<<"unlicensed">>` for a database published but never bought. `redistribution` says what your license permits you to do with the data, and is `null` when there is no license.

A license covers a family (`bogon_ip`), while a download names one of its versions (`bogon_ip_v1`), so the ids the other calls take come from a family's `versions` rather than from the family itself. Old versions are frozen rather than migrated, so both stay downloadable.

**The catalog is not the same for everyone.** A database commissioned for a single customer is simply absent from your listing rather than shown with an `unlicensed` standing, so read the listing this client returns: do not hold on to one and reuse it under a different key, and do not assemble a catalog from anywhere else.

### What is in a database

`database_metadata/2` describes one version without downloading any of it, so it is cheap to poll and it is what to check a transfer against before starting one:

```erlang
{ok, Metadata} = internetdata:database_metadata(Client, <<"bogon_ip_v1">>),

maps:get(updated, Metadata).                        % <<"2026-09-04">>, the day this build was made
maps:get(entries, Metadata).                        % row count
maps:get(<<"csvgz">>, maps:get(size, Metadata)).    % bytes
```

`schema`, `sample` and `size` are keyed by format, and a sample row is keyed by the dataset's own column names. Those keys stay binaries, because they are the server's to choose; the fields the API documents are atoms. Same rule everywhere in this library.

### Downloading

`database_download/4` streams a database straight to a file. Nothing beyond a single chunk is ever held in memory, so the size of the dataset does not matter:

```erlang
{ok, Written} = internetdata:database_download(Client, <<"bogon_ip_v1">>, csvgz, "bogon_ip.csv.gz").
```

The bytes go to a neighboring `.part` file that is renamed only once the whole body has arrived, so a transfer that dies halfway leaves neither a truncated file that reads as a complete database nor a `.part` for the next attempt to append to.

For a small database you can take the bytes directly. This holds the whole file in memory, and the published catalog runs from a few hundred bytes to several gigabytes, so check `size` first for anything you have not measured:

```erlang
{ok, Bytes} = internetdata:database_download_bytes(Client, <<"bogon_ip_v1">>, csvgz).
```

`database_download_url/3` hands back the link instead of the bytes, so you can transfer it however you like. The API answers a redirect straight to object storage and the returned URL carries **no credential of yours**, so it is safe to pass to another process, another machine, or `curl`:

```erlang
{ok, Url} = internetdata:database_download_url(Client, <<"bogon_ip_v1">>, mmdb).
```

It authorizes the START of a transfer, so one already running is not interrupted when the link lapses.

### Verifying a download

```erlang
{ok, Checksums} = internetdata:database_checksums(Client, <<"bogon_ip_v1">>, csvgz),
maps:get(sha256, Checksums).
```

Read the checksums after the transfer rather than before it: a build published in between then shows up as a mismatch instead of passing against the digest of a file you no longer have.

### Download history

`database_downloads/1` lists your organization's recent download attempts, newest first, refusals included. A denial is what answers "it stopped working", and its absence answers nothing:

```erlang
{ok, Attempts} = internetdata:database_downloads(Client, #{limit => 20}),

[io:format("~s ~s ~s~n", [maps:get(created, A), maps:get(dataset_id, A), maps:get(outcome, A)])
 || A <- Attempts].
```

### Errors

A failure answers `{error, Error}`, where `Error` is a map carrying a `kind` and a `retryable` flag:

```erlang
case internetdata:database_download_url(Client, <<"vpn_ip_v1">>, mmdb) of
    {ok, Url} ->
        fetch(Url);
    {error, #{kind := forbidden, message := Rc}} ->
        io:format("not licensed: ~s~n", [Rc]);
    {error, Error} ->
        io:format("~p: ~s~n", [maps:get(kind, Error), maps:get(message, Error)])
end.
```

`kind` is one of `bad_request`, `unauthorized`, `forbidden`, `rate_limited`, `quota_exceeded`, `server_error`, `network` or `io`. `status` carries the HTTP status where there was one, and `message` is the API's own result code, so `NOT_LICENSED` and `LICENSE_EXPIRED` tell you which 403 you got without having to ask us.

Note that `rate_limited` and `quota_exceeded` both arrive as HTTP 429 and are not the same thing. A rate limit is when the API faces extreme traffic bursts and so retrying later works; but a spent quota needs your allowance raised or the window to roll over. The library retries rate limits for you, but not if your quota is exceeded.

### Timeouts and retries

```erlang
Client = internetdata:new(#{api_key => <<"your-api-key">>, retries => 4, timeout_ms => 60000}).
```

`timeout_ms` bounds the wait for a whole request, except during a download, where it bounds the wait between chunks instead: a deadline that suits a listing is the wrong one for a gigabyte, while a transfer that has stopped making progress is stalled at any size.

## Other Libraries

There are official InternetData client libraries available for many languages including PHP, Python, Go, Java, Ruby, and many popular frameworks such as Django, Rails, and Laravel. See our GitHub at https://github.com/internetdata for more.

## About InternetData

IP, ASN and Domain data to reveal unique insights about the internet. APIs, Databases and Live Feeds available.

[<img src="https://s3.internetdata.io/internetdata-public/brand/mark.svg" alt="InternetData" width="96"/>](https://internetdata.io/)

## License

This project is licensed under the [MIT License](LICENSE).

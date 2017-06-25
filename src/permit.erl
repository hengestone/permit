%% @doc 
%%   https://crackstation.net/hashing-security.htm
%%   1. hash and salt password using sha256 and 256-bit salt
%%   2. use PBKDF2 to stretch key
%%   3. encrypt hash using AES
%%
%% @todo
%%   * associate user data with cert (root + pubkey e.g. first/last names, device id, etc)
%%   * associate token scope with cert
%%   * management interface to revoke key
-module(permit).
-include("permit.hrl").
-compile({parse_transform, category}).

-export([start/0, ephemeral/0]).
-export([
   create/2, 
   create/3,
   update/2,
   update/3,
   lookup/1,
   pubkey/1,
   pubkey/2,
   revoke/1,
   auth/2, 
   auth/3, 
   auth/4,
   issue/2,
   issue/3,
   validate/1
]).
-export_type([access/0, secret/0, token/0, claims/0, pubkey/0]).

%%
%% data types
-type access()   :: binary().
-type secret()   :: binary().
-type token()    :: binary().
-type claims()   :: #{binary() => _}.
-type pubkey()   :: #{binary() => _}.

%%
%%
start() ->
   applib:boot(?MODULE, code:where_is_file("app.config")).


ephemeral() ->
   pts:start_link(permit, [
      'read-through',
      {factory, temporary},
      {entity,  {permit_pubkey_io, start_link, [undefined]}}
   ]).


%%
%% Create a new pubkey pair, declare unique access and secret identity.
%% The process derives a new pair, stores it and return an identity token.
%%
%% {ok, Token} = permit:create("joe@example.com", "secret").
%%
-spec create(access(), secret()) -> {ok, token()} | {error, _}.
-spec create(access(), secret(), claims()) -> {ok, token()} | {error, _}.

create(Access, Secret) ->
   create(Access, Secret, default_claims()).

create(Access, Secret, Claims)
 when is_binary(Access), is_binary(Secret) ->
   [either ||
      permit_pubkey:new(Access, Secret, Claims),
      permit_pubkey_io:create(_),
      permit_pubkey:authenticate(_, Secret)
   ];

create(Access, Secret, Roles) ->
   create(scalar:s(Access), scalar:s(Secret), Roles).

%%
%% Update an existed pubkey pair, use unique access to substitute secret key
%% all allocated tokens becomes invalid
-spec update(access(), secret()) -> {ok, token()} | {error, _}.
-spec update(access(), secret(), claims()) -> {ok, token()} | {error, _}.

update(Access, Secret) ->
   update(Access, Secret, default_claims()).

update(Access, Secret, Claims)
 when is_binary(Access), is_binary(Secret) ->
   [either ||
      permit_pubkey:new(Access, Secret, Claims),
      permit_pubkey_io:update(_),
      permit_pubkey:authenticate(_, Secret)
   ];

update(Access, Secret, Claims) ->
   update(scalar:s(Access), scalar:s(Secret), Claims).

%%
%% Lookup an existed pubkey pair, use unique access and secret to prove identity.
%% The process validates a pair against existed one and returns an identity token.  
%%
%% {ok, Token} = permit:signup("joe@example.com", "secret").
%%
-spec lookup(access()) -> {ok, token()} | {error, any()}.

lookup(Access) ->
   permit_pubkey_io:lookup(scalar:s(Access)).

%%
%% revoke pubkey pair associated with access key
-spec revoke(access()) -> {ok, _} | {error, _}.

revoke(Access) ->
   [either ||
      permit_pubkey_io:lookup(scalar:s(Access)),
      permit_pubkey_io:remove(_)
   ].


%%
%% derive a new pubkey pair from master access key
-spec pubkey(access()) -> {ok, map()} | {error, any()}.
-spec pubkey(access(), claims()) -> {ok, map()} | {error, any()}.

pubkey(Master) ->
   pubkey(Master, default_claims()).

pubkey(Master, Claims) ->
   Access = permit_hash:key(?CONFIG_ACCESS),
   Secret = permit_hash:key(?CONFIG_SECRET),
   [either ||
      permit:lookup(Master),
      permit_pubkey:new(Access, Secret, Claims),
      fmap(lens:put(permit_pubkey:master(), scalar:s(Master), _)),
      permit_pubkey_io:create(_),
      pubkey_access_pair_new(_, Access, Secret)
   ].

pubkey_access_pair_new(_PubKey, Access, Secret) ->
   {ok, [$. ||
      fmap(#{}),
      lens:put(permit_pubkey:access(), Access, _),
      lens:put(permit_pubkey:secret(), Secret, _)
   ]}.

%%
%% Authenticate using unique access and secret to prove identity
%% Returns a token bounded to given roles.
-spec auth(access(), secret()) -> {ok, token()} | {error, _}. 
-spec auth(access(), secret(), timeout()) -> {ok, token()} | {error, _}. 
-spec auth(access(), secret(), timeout(), claims()) -> {ok, token()} | {error, _}. 

auth(Access, Secret) ->
   [either ||
      permit_pubkey_io:lookup(scalar:s(Access)),
      permit_pubkey:authenticate(_, Secret)
   ].

auth(Access, Secret, TTL) ->
   [either ||
      permit_pubkey_io:lookup(scalar:s(Access)),
      permit_pubkey:authenticate(_, Secret, TTL)
   ].
   
auth(Access, Secret, TTL, Roles) ->
   [either ||
      permit_pubkey_io:lookup(scalar:s(Access)),
      permit_pubkey:authenticate(_, Secret, TTL, Roles)
   ].

%%
%% create access token for identity bypass password
-spec issue(access(), timeout()) -> {ok, token()} | {error, _}. 
-spec issue(access(), timeout(), claims()) -> {ok, token()} | {error, _}. 

issue(Access, TTL) ->
   [either ||
      permit_pubkey_io:lookup(scalar:s(Access)),
      permit_token:new(_, TTL)
   ].

issue(Access, TTL, Claims) ->
   [either ||
      permit_pubkey_io:lookup(scalar:s(Access)),
      permit_token:new(_, TTL, Claims)
   ].
   
%%
%% validate access token
-spec validate(token()) -> {ok, map()} | {error, _}.

validate(Token) ->
   [either ||
      jwt:decode(Token, scalar:s(opts:val(secret, permit))),
      fmap(lens:get(lens:map(<<"sub">>), _)),
      permit_pubkey_io:lookup(_),
      fmap(lens:get(permit_pubkey:secret(), _)),
      permit_token:check(Token, _)
   ].

%%
%%
default_claims() ->
   [$. ||
      opts:val(roles, permit),
      scalar:s(_),
      binary:split(_, <<$ >>, [trim, global]),
      lists:map(fun(X) -> {X, true} end, _),
      maps:from_list(_)
   ].


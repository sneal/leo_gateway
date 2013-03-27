%%======================================================================
%%
%% Leo Gateway
%%
%% Copyright (c) 2012 Rakuten, Inc.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% ---------------------------------------------------------------------
%% Leo Gateway - HTTP Commons Handler
%% @doc
%% @end
%%======================================================================
-module(leo_gateway_http_handler).

-author('Yosuke Hara').

-include("leo_gateway.hrl").
-include("leo_http.hrl").
-include_lib("leo_logger/include/leo_logger.hrl").
-include_lib("leo_object_storage/include/leo_object_storage.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([start/1, start/2, stop/0]).
-export([onrequest/2, onresponse/2]).
-export([invoke/4, put_obj/4]).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------
%% @doc Launch http handler
%%
-spec(start(atom(), #http_options{}) ->
             ok).
start(Sup, Options) ->
    %% for ECache
    NumOfECacheWorkers    = Options#http_options.cache_workers,
    CacheRAMCapacity      = Options#http_options.cache_ram_capacity,
    CacheDiscCapacity     = Options#http_options.cache_disc_capacity,
    CacheDiscThresholdLen = Options#http_options.cache_disc_threshold_len,
    CacheDiscDirData      = Options#http_options.cache_disc_dir_data,
    CacheDiscDirJournal   = Options#http_options.cache_disc_dir_journal,
    ChildSpec0 = {ecache_sup,
                  {ecache_sup, start_link, [NumOfECacheWorkers, CacheRAMCapacity, CacheDiscCapacity,
                                            CacheDiscThresholdLen, CacheDiscDirData, CacheDiscDirJournal]},
                  permanent, ?SHUTDOWN_WAITING_TIME, supervisor, [ecache_sup]},
    {ok, _} = supervisor:start_child(Sup, ChildSpec0),

    %% for Cowboy
    ChildSpec1 = {cowboy_sup,
                  {cowboy_sup, start_link, []},
                  permanent, ?SHUTDOWN_WAITING_TIME, supervisor, [cowboy_sup]},
    {ok, _} = supervisor:start_child(Sup, ChildSpec1),

    %% launch http-handler(s)
    start(Options).


-spec(start(#http_options{}) ->
             ok).
start(#http_options{handler                = Handler,
                    port                   = Port,
                    ssl_port               = SSLPort,
                    ssl_certfile           = SSLCertFile,
                    ssl_keyfile            = SSLKeyFile,
                    num_of_acceptors       = NumOfAcceptors,
                    cache_method           = CacheMethod,
                    cache_expire           = CacheExpire,
                    cache_max_content_len  = CacheMaxContentLen,
                    cachable_content_type  = CachableContentTypes,
                    cachable_path_pattern  = CachablePathPatterns} = Props) ->
    InternalCache = (CacheMethod == 'inner'),
    Dispatch      = cowboy_router:compile(
                      [{'_', [{'_', Handler,
                               [?env_layer_of_dirs(), InternalCache, Props]}]}]),

    Config = case InternalCache of
                 %% Using inner-cache
                 true ->
                     [{env, [{dispatch, Dispatch}]}];
                 %% Using http-cache
                 false ->
                     CacheCondition = #cache_condition{expire          = CacheExpire,
                                                       max_content_len = CacheMaxContentLen,
                                                       content_types   = CachableContentTypes,
                                                       path_patterns   = CachablePathPatterns},
                     [{env,        [{dispatch, Dispatch}]},
                      {onrequest,  Handler:onrequest(CacheCondition)},
                      {onresponse, Handler:onresponse(CacheCondition)}]
             end,

    {ok, _Pid1}= cowboy:start_http(Handler, NumOfAcceptors,
                                   [{port, Port}], Config),
    {ok, _Pid2}= cowboy:start_https(list_to_atom(lists:append([atom_to_list(Handler), "_ssl"])),
                                    NumOfAcceptors,
                                    [{port,     SSLPort},
                                     {certfile, SSLCertFile},
                                     {keyfile,  SSLKeyFile}],
                                    Config),
    ok.


%% @doc Stop proc(s)
%%
-spec(stop() ->
             ok).
stop() ->
    {ok, HttpOption} = leo_gateway_app:get_options(),
    Handler = HttpOption#http_options.handler,
    cowboy:stop_listener(Handler),
    cowboy:stop_listener(list_to_atom(lists:append([atom_to_list(Handler), "_ssl"]))),
    ok.


%%--------------------------------------------------------------------
%%
%%--------------------------------------------------------------------
%% @doc Handle request
%%
onrequest(#cache_condition{expire = Expire}, FunGenKey) ->
    fun(Req) ->
            Method = cowboy_req:get(method, Req),
            onrequest_1(Method, Req, Expire, FunGenKey)
    end.

onrequest_1(?HTTP_GET, Req, Expire, FunGenKey) ->
    Key = FunGenKey(Req),
    Ret = ecache_api:get(Key),
    onrequest_2(Req, Expire, Key, Ret);
onrequest_1(_, Req,_,_) ->
    Req.

onrequest_2(Req,_Expire,_Key, not_found) ->
    Req;
onrequest_2(Req, Expire, Key, {ok, CachedObj}) ->
    #cache{mtime        = MTime,
           content_type = ContentType,
           etag         = Checksum,
           body         = Body} = binary_to_term(CachedObj),

    Now = leo_date:now(),
    Diff = Now - MTime,

    case (Diff > Expire) of
        true ->
            _ = ecache_api:delete(Key),
            Req;
        false ->
            LastModified = leo_http:rfc1123_date(MTime),
            Header = [?SERVER_HEADER,
                      {?HTTP_HEAD_LAST_MODIFIED, LastModified},
                      {?HTTP_HEAD_CONTENT_TYPE,  ContentType},
                      {?HTTP_HEAD_AGE,           integer_to_list(Diff)},
                      {?HTTP_HEAD_ETAG4AWS,      lists:append(["\"",leo_hex:integer_to_hex(Checksum, 32),"\""])},
                      {?HTTP_HEAD_CACHE_CTRL,    lists:append(["max-age=",integer_to_list(Expire)])}
                     ],
            IMSSec = case cowboy_req:parse_header(?HTTP_HEAD_IF_MODIFIED_SINCE, Req) of
                         {ok, undefined, _} ->
                             0;
                         {ok, IMSDateTime, _} ->
                             calendar:datetime_to_gregorian_seconds(IMSDateTime)
                     end,
            case IMSSec of
                MTime ->
                    {ok, Req2} = ?reply_not_modified(Header, Req),
                    Req2;
                _ ->
                    Req2 = cowboy_req:set_resp_body(Body, Req),
                    {ok, Req3} = ?reply_ok([?SERVER_HEADER], Req2),
                    Req3
            end
    end.


%% @doc
%%
onresponse(#cache_condition{expire = Expire} = Config, FunGenKey) ->
    fun(?HTTP_ST_OK, Headers, Body, Req) ->
            case cowboy_req:get(method, Req) of
                ?HTTP_GET ->
                    Key = FunGenKey(Req),

                    case lists:all(fun(Fun) ->
                                           Fun(Key, Config, Headers, Body)
                                   end, [fun is_cachable_req1/4,
                                         fun is_cachable_req2/4,
                                         fun is_cachable_req3/4]) of
                        true ->
                            Now = leo_date:now(),
                            ContentType = case lists:keyfind(?HTTP_HEAD_CONTENT_TYPE, 1, Headers) of
                                              false ->
                                                  ?HTTP_CTYPE_OCTET_STREAM;
                                              {_, Val} ->
                                                  Val
                                          end,

                            Bin = term_to_binary(
                                    #cache{mtime        = Now,
                                           etag         = leo_hex:raw_binary_to_integer(crypto:md5(Body)),
                                           content_type = ContentType,
                                           body         = Body}),
                            _ = ecache_api:put(Key, Bin),

                            Headers2 = lists:keydelete(?HTTP_HEAD_LAST_MODIFIED, 1, Headers),
                            Headers3 = [{?HTTP_HEAD_CACHE_CTRL, lists:append(["max-age=",integer_to_list(Expire)])},
                                        {?HTTP_HEAD_LAST_MODIFIED, leo_http:rfc1123_date(Now)}
                                        |Headers2],
                            {ok, Req2} = ?reply_ok(Headers3, Req),
                            Req2;
                        false ->
                            cowboy_req:set_resp_body(<<>>, Req)
                    end;
                _ ->
                    cowboy_req:set_resp_body(<<>>, Req)
            end
    end.


%% Compile Options:
%%
-compile({inline, [invoke/4, get_obj_with_etag/4, put_obj/4, put_obj_1/5, put_obj_2/3, put_obj_3/2,
                   put_small_object/3, put_large_object/4]}).


%% @doc Constraint violation.
invoke(_HTTPMethod, Req,_Key, #req_params{token_length = Len,
                                          max_layers   = Max}) when Len > Max ->
    ?reply_not_found([?SERVER_HEADER], Req);


%% ---------------------------------------------------------------------
%% For BUCKET-OPERATION
%% ---------------------------------------------------------------------
%% @doc GET operation on buckets & Dirs.
invoke(?HTTP_GET, Req, Key, #req_params{is_dir = true,
                                        access_key_id = AccessKeyId,
                                        qs_prefix     = Prefix}) ->
    case leo_gateway_s3_bucket:get_bucket_list(AccessKeyId, Key, none, none, 1000, Prefix) of
        {ok, Meta, XML} when is_list(Meta) == true ->
            Req2 = cowboy_req:set_resp_body(XML, Req),
            ?reply_ok([?SERVER_HEADER,
                       {?HTTP_HEAD_CONTENT_TYPE, ?HTTP_CTYPE_XML}
                      ], Req2);
        {error, not_found} ->
            ?reply_not_found([?SERVER_HEADER], Req);
        {error, ?ERR_TYPE_INTERNAL_ERROR} ->
            ?reply_internal_error([?SERVER_HEADER], Req);
        {error, timeout} ->
            ?reply_timeout([?SERVER_HEADER], Req)
    end;

%% @doc PUT operation on buckets.
invoke(?HTTP_PUT, Req, Key, #req_params{token_length  = 1,
                                        access_key_id = AccessKeyId}) ->
    Bucket = case (?BIN_SLASH == binary:part(Key, {byte_size(Key)-1, 1})) of
                 true ->
                     binary:part(Key, {0, byte_size(Key) -1});
                 false ->
                     Key
             end,
    case leo_gateway_s3_bucket:put_bucket(AccessKeyId, Bucket) of
        ok ->
            ?reply_ok([?SERVER_HEADER], Req);
        {error, ?ERR_TYPE_INTERNAL_ERROR} ->
            ?reply_internal_error([?SERVER_HEADER], Req);
        {error, timeout} ->
            ?reply_timeout([?SERVER_HEADER], Req)
    end;

%% @doc DELETE operation on buckets.
%% @private
invoke(?HTTP_DELETE, Req, Key, #req_params{token_length  = 1,
                                           access_key_id = AccessKeyId}) ->
    case leo_gateway_s3_bucket:delete_bucket(AccessKeyId, Key) of
        ok ->
            ?reply_no_content([?SERVER_HEADER], Req);
        not_found ->
            ?reply_not_found([?SERVER_HEADER], Req);
        {error, ?ERR_TYPE_INTERNAL_ERROR} ->
            ?reply_internal_error([?SERVER_HEADER], Req);
        {error, timeout} ->
            ?reply_timeout([?SERVER_HEADER], Req)
    end;

%% @doc HEAD operation on buckets.
%% @private
invoke(?HTTP_HEAD, Req, Key, #req_params{token_length  = 1,
                                         access_key_id = AccessKeyId}) ->
    case leo_gateway_s3_bucket:head_bucket(AccessKeyId, Key) of
        ok ->
            ?reply_ok([?SERVER_HEADER], Req);
        not_found ->
            ?reply_not_found([?SERVER_HEADER], Req);
        {error, ?ERR_TYPE_INTERNAL_ERROR} ->
            ?reply_internal_error([?SERVER_HEADER], Req);
        {error, timeout} ->
            ?reply_timeout([?SERVER_HEADER], Req)
    end;


%% ---------------------------------------------------------------------
%% For OBJECT-OPERATION
%% ---------------------------------------------------------------------
%% @doc GET operation on Object with Range Header.
invoke(?HTTP_GET, Req, Key, #req_params{is_dir       = false,
                                        range_header = RangeHeader}) when RangeHeader /= undefined ->
    [_,ByteRangeSpec|_] = string:tokens(binary_to_list(RangeHeader), "="),
    ByteRangeSet = string:tokens(ByteRangeSpec, "-"),
    {Start, End} = case length(ByteRangeSet) of
                       1 ->
                           [StartStr|_] = ByteRangeSet,
                           {list_to_integer(StartStr), 0};
                       2 ->
                           [StartStr,EndStr|_] = ByteRangeSet,
                           {list_to_integer(StartStr), list_to_integer(EndStr) + 1};
                       _ ->
                           {undefined, undefined}
                   end,
    case Start of
        undefined ->
            ?reply_bad_range([?SERVER_HEADER], Req);
        _ ->
            case leo_gateway_rpc_handler:get(Key, Start, End) of
                {ok, _Meta, RespObject} ->
                    Mime = leo_mime:guess_mime(Key),
                    Req2 = cowboy_req:set_resp_body(RespObject, Req),
                    ?reply_partial_content([?SERVER_HEADER,
                                            {?HTTP_HEAD_CONTENT_TYPE,  Mime}],
                                           Req2);
                {error, not_found} ->
                    ?reply_not_found([?SERVER_HEADER], Req);
                {error, ?ERR_TYPE_INTERNAL_ERROR} ->
                    ?reply_internal_error([?SERVER_HEADER], Req);
                {error, timeout} ->
                    ?reply_timeout([?SERVER_HEADER], Req)
            end
    end;

%% @doc GET operation on Object if inner cache is enabled.
%% @private
invoke(?HTTP_GET = HTTPMethod, Req, Key, #req_params{is_dir = false,
                                                     is_cached = true,
                                                     has_inner_cache = true} = Params) ->
    case ecache_api:get(Key) of
        not_found ->
            invoke(HTTPMethod, Req, Key, Params#req_params{is_cached = false});
        {ok, CachedObj} ->
            Cached = binary_to_term(CachedObj),
            get_obj_with_etag(Req, Key, Params, Cached)
    end;

%% @doc GET operation on Object.
%% @private
invoke(?HTTP_GET, Req, Key, #req_params{is_dir = false,
                                        has_inner_cache = HasInnerCache}) ->
    case leo_gateway_rpc_handler:get(Key) of
        %% For regular case (NOT a chunked object)
        {ok, #metadata{cnumber = 0} = Meta, RespObject} ->
            Mime = leo_mime:guess_mime(Key),

            case HasInnerCache of
                true ->
                    BinVal = term_to_binary(#cache{etag = Meta#metadata.checksum,
                                                   mtime = Meta#metadata.timestamp,
                                                   content_type = Mime,
                                                   body = RespObject}),
                    _ = ecache_api:put(Key, BinVal);
                false ->
                    void
            end,
            Req2 = cowboy_req:set_resp_body(RespObject, Req),
            ?reply_ok([?SERVER_HEADER,
                       {?HTTP_HEAD_CONTENT_TYPE,  Mime},
                       {?HTTP_HEAD_ETAG4AWS, lists:append(["\"",
                                                           leo_hex:integer_to_hex(Meta#metadata.checksum, 32),
                                                           "\""])},
                       {?HTTP_HEAD_LAST_MODIFIED, leo_http:rfc1123_date(Meta#metadata.timestamp)}],
                      Req2);

        %% For a chunked object.
        {ok, #metadata{cnumber = TotalChunkedObjs}, _RespObject} ->
            {ok, Pid}  = leo_gateway_large_object_handler:start_link(Key),
            {ok, Req2} = cowboy_req:chunked_reply(?HTTP_ST_OK, [?SERVER_HEADER], Req),

            Ret = leo_gateway_large_object_handler:get(Pid, TotalChunkedObjs, Req2),
            catch leo_gateway_large_object_handler:stop(Pid),

            case Ret of
                {ok, Req3} ->
                    {ok, Req3};
                {error, Cause} ->
                    ?error("exec1/4", "path:~s, cause:~p", [binary_to_list(Key), Cause]),
                    ?reply_internal_error([?SERVER_HEADER], Req)
            end;
        {error, not_found} ->
            ?reply_not_found([?SERVER_HEADER], Req);
        {error, ?ERR_TYPE_INTERNAL_ERROR} ->
            ?reply_internal_error([?SERVER_HEADER], Req);
        {error, timeout} ->
            ?reply_timeout([?SERVER_HEADER], Req)
    end;

%% @doc HEAD operation on Object.
%% @private
invoke(?HTTP_HEAD, Req, Key, _Params) ->
    case leo_gateway_rpc_handler:head(Key) of
        {ok, #metadata{del = 0} = Meta} ->
            Timestamp = leo_http:rfc1123_date(Meta#metadata.timestamp),
            Headers   = [?SERVER_HEADER,
                         {?HTTP_HEAD_CONTENT_TYPE, leo_mime:guess_mime(Key)},
                         {?HTTP_HEAD_ETAG4AWS, lists:append(["\"",
                                                             leo_hex:integer_to_hex(Meta#metadata.checksum, 32),
                                                             "\""])},
                         {?HTTP_HEAD_CONTENT_LENGTH, erlang:integer_to_list(Meta#metadata.dsize)},
                         {?HTTP_HEAD_LAST_MODIFIED,  Timestamp}],
            ?reply_ok(Headers, Req);
        {ok, #metadata{del = 1}} ->
            ?reply_not_found([?SERVER_HEADER], Req);
        {error, not_found} ->
            ?reply_not_found([?SERVER_HEADER], Req);
        {error, ?ERR_TYPE_INTERNAL_ERROR} ->
            ?reply_internal_error([?SERVER_HEADER], Req);
        {error, timeout} ->
            ?reply_timeout([?SERVER_HEADER], Req)
    end;

%% @doc DELETE operation on Object.
%% @private
invoke(?HTTP_DELETE, Req, Key, _Params) ->
    case leo_gateway_rpc_handler:delete(Key) of
        ok ->
            ?reply_no_content([?SERVER_HEADER], Req);
        {error, not_found} ->
            ?reply_not_found([?SERVER_HEADER], Req);
        {error, ?ERR_TYPE_INTERNAL_ERROR} ->
            ?reply_internal_error([?SERVER_HEADER], Req);
        {error, timeout} ->
            ?reply_timeout([?SERVER_HEADER], Req)
    end;

%% @doc POST/PUT operation on Objects.
%% @private
invoke(?HTTP_PUT, Req, Key, #req_params{handler = ?HTTP_HANDLER_S3} = Params) ->
    put_obj(?http_header(Req, ?HTTP_HEAD_X_AMZ_META_DIRECTIVE), Req, Key, Params);

%% @doc invalid request.
%% @private
invoke(_, Req, _, _) ->
    ?reply_bad_request([?SERVER_HEADER], Req).


%%--------------------------------------------------------------------
%% INNER Functions
%%--------------------------------------------------------------------
%% @doc Judge cachable request
%% @private
is_cachable_req1(_Key, #cache_condition{max_content_len = MaxLen}, Headers, Body) ->
    HasNOTCacheControl = (false == lists:keyfind(?HTTP_HEAD_CACHE_CTRL, 1, Headers)),
    HasNOTCacheControl  andalso
        is_binary(Body) andalso
        size(Body) > 0  andalso
        size(Body) < MaxLen.

is_cachable_req2(_Key, #cache_condition{path_patterns = []}, _Headers, _Body) ->
    true;
is_cachable_req2(_Key, #cache_condition{path_patterns = undefined}, _Headers, _Body) ->
    true;
is_cachable_req2( Key, #cache_condition{path_patterns = PathPatterns}, _Headers, _Body) ->
    Res = lists:any(fun(Path) ->
                            nomatch /= re:run(Key, Path)
                    end, PathPatterns),
    Res.

is_cachable_req3(_, #cache_condition{content_types = []}, _Headers, _Body) ->
    true;
is_cachable_req3(_, #cache_condition{content_types = undefined}, _Headers, _Body) ->
    true;
is_cachable_req3(_Key, #cache_condition{content_types = ContentTypeList}, Headers, _Body) ->
    case lists:keyfind(?HTTP_HEAD_CONTENT_TYPE, 1, Headers) of
        false ->
            false;
        {_, ContentType} ->
            lists:member(ContentType, ContentTypeList)
    end.

%% @doc GET operation with Etag
%% @private
get_obj_with_etag(Req, Key, #req_params{is_dir = false, has_inner_cache = true}, Cached) ->
    case leo_gateway_rpc_handler:get(Key, Cached#cache.etag) of
        {ok, match} ->
            Req2 = cowboy_req:set_resp_body(Cached#cache.body, Req),
            ?reply_ok([?SERVER_HEADER,
                       {?HTTP_HEAD_CONTENT_TYPE,  Cached#cache.content_type},
                       {?HTTP_HEAD_ETAG4AWS, lists:append(["\"",
                                                           leo_hex:integer_to_hex(Cached#cache.etag, 32),
                                                           "\""])},
                       {?HTTP_HEAD_LAST_MODIFIED, leo_http:rfc1123_date(Cached#cache.mtime)},
                       {?HTTP_HEAD_X_FROM_CACHE,  <<"True">>}],
                      Req2);
        {ok, Meta, RespObject} ->
            Mime = leo_mime:guess_mime(Key),
            BinVal = term_to_binary(#cache{etag = Meta#metadata.checksum,
                                           mtime = Meta#metadata.timestamp,
                                           content_type = Mime,
                                           body = RespObject}),

            _ = ecache_api:put(Key, BinVal),

            Req2 = cowboy_req:set_resp_body(RespObject, Req),
            ?reply_ok([?SERVER_HEADER,
                       {?HTTP_HEAD_CONTENT_TYPE,  Mime},
                       {?HTTP_HEAD_ETAG4AWS, lists:append(["\"",
                                                           leo_hex:integer_to_hex(Meta#metadata.checksum, 32),
                                                           "\""])},
                       {?HTTP_HEAD_LAST_MODIFIED, leo_http:rfc1123_date(Meta#metadata.timestamp)}],
                      Req2);
        {error, not_found} ->
            ?reply_not_found([?SERVER_HEADER], Req);
        {error, ?ERR_TYPE_INTERNAL_ERROR} ->
            ?reply_internal_error([?SERVER_HEADER], Req);
        {error, timeout} ->
            ?reply_timeout([?SERVER_HEADER], Req)
    end.


%% @doc POST/PUT operation on Objects. NORMAL
%% @private
put_obj(?BIN_EMPTY, Req, Key, Params) ->
    {Size0, _} = cowboy_req:body_length(Req),

    case (Size0 >= Params#req_params.threshold_obj_len) of
        true when Size0 >= Params#req_params.max_len_for_obj ->
            ?reply_bad_request([?SERVER_HEADER], Req);
        true when Params#req_params.is_upload == false ->
            put_large_object(Req, Key, Size0, Params);
        false ->
            Ret = case cowboy_req:has_body(Req) of
                      true ->
                          case cowboy_req:body(Req) of
                              {ok, Bin0, Req0} ->
                                  {ok, {Size0, Bin0, Req0}};
                              {error, Cause} ->
                                  {error, Cause}
                          end;
                      false ->
                          {ok, {0, ?BIN_EMPTY, Req}}
                  end,
            put_small_object(Ret, Key, Params)
    end;

%% @doc POST/PUT operation on Objects. COPY/REPLACE
%% @private
put_obj(Directive, Req, Key, #req_params{handler = ?HTTP_HANDLER_S3}) ->
    CS = ?http_header(Req, ?HTTP_HEAD_X_AMZ_COPY_SOURCE),

    %% need to trim head '/' when cooperating with s3fs(-c)
    CS2 = case binary:part(CS, {0, 1}) of
              ?BIN_SLASH ->
                  binary:part(CS, {1, byte_size(CS) -1});
              _ ->
                  CS
          end,

    case leo_gateway_rpc_handler:get(CS2) of
        {ok, Meta, RespObject} ->
            put_obj_1(Directive, Req, Key, Meta, RespObject);
        {error, not_found} ->
            ?reply_not_found([?SERVER_HEADER], Req);
        {error, ?ERR_TYPE_INTERNAL_ERROR} ->
            ?reply_internal_error([?SERVER_HEADER], Req);
        {error, timeout} ->
            ?reply_timeout([?SERVER_HEADER], Req)
    end.

%% @doc POST/PUT operation on Objects. COPY
%% @private
put_obj_1(Directive, Req, Key, Meta, Bin) ->
    Size = size(Bin),

    case leo_gateway_rpc_handler:put(Key, Bin, Size) of
        {ok, _ETag} when Directive == ?HTTP_HEAD_X_AMZ_META_DIRECTIVE_COPY ->
            resp_copy_obj_xml(Req, Meta);
        {ok, _ETag} when Directive == ?HTTP_HEAD_X_AMZ_META_DIRECTIVE_REPLACE ->
            put_obj_2(Req, Key, Meta);
        {error, ?ERR_TYPE_INTERNAL_ERROR} ->
            ?reply_internal_error([?SERVER_HEADER], Req);
        {error, timeout} ->
            ?reply_timeout([?SERVER_HEADER], Req)
    end.


%% @doc POST/PUT operation on Objects. REPLACE
%% @private
put_obj_2(Req, Key, Meta) ->
    KeyList = binary_to_list(Key),
    case KeyList == Meta#metadata.key of
        true  -> resp_copy_obj_xml(Req, Meta);
        false -> put_obj_3(Req, Meta)
    end.

put_obj_3(Req, Meta) ->
    KeyBin = list_to_binary(Meta#metadata.key),
    case leo_gateway_rpc_handler:delete(KeyBin) of
        ok ->
            resp_copy_obj_xml(Req, Meta);
        {error, not_found} ->
            resp_copy_obj_xml(Req, Meta);
        {error, ?ERR_TYPE_INTERNAL_ERROR} ->
            ?reply_internal_error([?SERVER_HEADER], Req);
        {error, timeout} ->
            ?reply_timeout([?SERVER_HEADER], Req)
    end.


%% @doc Put a small object into the storage
%% @private
put_small_object({error, Cause}, _, _) ->
    {error, Cause};
put_small_object({ok, {Size, Bin, Req}}, Key, Params) ->
    CIndex = case Params#req_params.upload_part_num of
                 <<>> -> 0;
                 PartNum ->
                     case is_integer(PartNum) of
                         true ->
                             PartNum;
                         false ->
                             list_to_integer(binary_to_list(PartNum))
                     end
             end,

    case leo_gateway_rpc_handler:put(Key, Bin, Size, CIndex) of
        {ok, ETag} ->
            case Params#req_params.has_inner_cache of
                true  ->
                    Mime = leo_mime:guess_mime(Key),
                    BinVal = term_to_binary(#cache{etag = ETag,
                                                   mtime = leo_date:now(),
                                                   content_type = Mime,
                                                   body = Bin}),
                    _ = ecache_api:put(Key, BinVal);
                false -> void
            end,
            ?reply_ok([?SERVER_HEADER,
                       {?HTTP_HEAD_ETAG4AWS,
                        lists:append(["\"",
                                      leo_hex:integer_to_hex(ETag, 32),
                                      "\""])}
                      ], Req);
        {error, ?ERR_TYPE_INTERNAL_ERROR} ->
            ?reply_internal_error([?SERVER_HEADER], Req);
        {error, timeout} ->
            ?reply_timeout([?SERVER_HEADER], Req)
    end.


%% @doc Put a large-object into the storage
%% @private
put_large_object(Req, Key, Size, #req_params{chunked_obj_len=ChunkedSize})->
    {ok, Pid}  = leo_gateway_large_object_handler:start_link(Key),

    Ret2 = case catch put_large_object(
                        cowboy_req:stream_body(Req), Key, Size, ChunkedSize, 0, 1, Pid) of
               {'EXIT', Cause} ->
                   {error, Cause};
               Ret1 ->
                   Ret1
           end,
    catch leo_gateway_large_object_handler:stop(Pid),
    Ret2.

put_large_object({ok, Data, Req}, Key, Size, ChunkedSize, TotalSize, Counter, Pid) ->
    DataSize = byte_size(Data),

    catch leo_gateway_large_object_handler:put(Pid, ChunkedSize, Data),
    put_large_object(cowboy_req:stream_body(Req), Key, Size, ChunkedSize,
                     TotalSize + DataSize, Counter + 1, Pid);

put_large_object({done, Req}, Key, Size, ChunkedSize, TotalSize, Counter, Pid) ->
    case catch leo_gateway_large_object_handler:put(Pid, done) of
        {ok, TotalChunks} ->
            case catch leo_gateway_large_object_handler:result(Pid) of
                {ok, Digest0} when Size == TotalSize ->
                    Digest1 = leo_hex:raw_binary_to_integer(Digest0),

                    case leo_gateway_rpc_handler:put(
                           Key, ?BIN_EMPTY, Size, ChunkedSize, TotalChunks, Digest1) of
                        {ok, _ETag} ->
                            ?reply_ok([?SERVER_HEADER,
                                       {?HTTP_HEAD_ETAG4AWS,
                                        lists:append(["\"",
                                                      leo_hex:integer_to_hex(Digest1, 32),
                                                      "\""])}
                                      ], Req);
                        {error, ?ERR_TYPE_INTERNAL_ERROR} ->
                            ?reply_internal_error([?SERVER_HEADER], Req);
                        {error, timeout} ->
                            ?reply_timeout([?SERVER_HEADER], Req)
                    end;
                {_, _Cause} ->
                    ok = leo_gateway_large_object_handler:rollback(Pid, TotalChunks),
                    ?reply_internal_error([?SERVER_HEADER], Req)
            end;
        {error, _Cause} ->
            ok = leo_gateway_large_object_handler:rollback(Pid, Counter),
            ?reply_internal_error([?SERVER_HEADER], Req)
    end;

%% An error occurred while reading the body, connection is gone.
put_large_object({error, Cause}, Key, _Size, _ChunkedSize, _TotalSize, Counter, Pid) ->
    ?error("handle_cast/2", "key:~s, cause:~p", [binary_to_list(Key), Cause]),
    ok = leo_gateway_large_object_handler:rollback(Pid, Counter).


%% @doc Generate copy-obj's xml
%% @private
resp_copy_obj_xml(Req, Meta) ->
    XML = io_lib:format(?XML_COPY_OBJ_RESULT,
                        [leo_http:web_date(Meta#metadata.timestamp),
                         leo_hex:integer_to_hex(Meta#metadata.checksum, 32)]),
    Req2 = cowboy_req:set_resp_body(XML, Req),
    ?reply_ok([?SERVER_HEADER,
               {?HTTP_HEAD_CONTENT_TYPE, ?HTTP_CTYPE_XML}
              ], Req2).


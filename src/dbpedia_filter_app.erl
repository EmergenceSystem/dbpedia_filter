%%%-------------------------------------------------------------------
%%% @doc DBpedia SPARQL agent.
%%%
%%% Uses the DBpedia Lookup API to find matching entities, then
%%% enriches each hit with its English abstract via a targeted
%%% SPARQL query on the known URI (no full-scan, no timeout).
%%% @end
%%%-------------------------------------------------------------------
-module(dbpedia_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/2]).

-define(LOOKUP_ENDPOINT, "https://lookup.dbpedia.org/api/search").
-define(SPARQL_ENDPOINT, "https://dbpedia.org/sparql").
-define(MAX_RESULTS, 10).

-define(CAPABILITIES, [
    <<"dbpedia">>,
    <<"sparql">>,
    <<"semantic">>,
    <<"encyclopedia">>,
    <<"wikipedia">>
]).

%%====================================================================
%% Application behaviour
%%====================================================================

start(_StartType, _StartArgs) ->
    em_filter:start_agent(dbpedia_filter, ?MODULE, #{
        capabilities => ?CAPABILITIES,
        memory       => ets
    }).

stop(_State) ->
    em_filter:stop_agent(dbpedia_filter).

%%====================================================================
%% Agent handler
%%====================================================================

handle(Body, Memory) when is_binary(Body) ->
    Seen    = maps:get(seen, Memory, #{}),
    Embryos = generate_embryo_list(Body),
    Fresh   = [E || E <- Embryos, not maps:is_key(url_of(E), Seen)],
    io:format("[dbpedia] value=~p results=~p fresh=~p~n",
              [Body, length(Embryos), length(Fresh)]),
    NewSeen = lists:foldl(fun(E, Acc) ->
        Acc#{url_of(E) => true}
    end, Seen, Fresh),
    {Fresh, Memory#{seen => NewSeen}};

handle(_Body, Memory) ->
    {[], Memory}.

%%====================================================================
%% Pipeline: Lookup -> abstract enrichment
%%====================================================================

generate_embryo_list(JsonBinary) ->
    {Value, Timeout, TypeClass} = extract_params(JsonBinary),
    case Value of
        [] -> [];
        _  ->
            Hits = lookup(Value, TypeClass, Timeout),
            enrich_with_abstracts(Hits, Timeout)
    end.

%% Step 1: DBpedia Lookup API — fast fulltext search, returns URIs + snippets.
lookup(Value, TypeClass, Timeout) ->
    TypeParam = case TypeClass of
        ""  -> "";
        _   -> "&typeName=" ++ uri_string:quote(TypeClass)
    end,
    Url = ?LOOKUP_ENDPOINT
          ++ "?query=" ++ uri_string:quote(Value)
          ++ "&maxResults=" ++ integer_to_list(?MAX_RESULTS)
          ++ TypeParam,
    Headers = [{"Accept", "application/json"}],
    case httpc:request(get, {Url, Headers}, [{timeout, Timeout * 1000}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            parse_lookup_response(Body);
        {ok, {{_, Status, _}, _, _}} ->
            io:format("[dbpedia] lookup HTTP ~p~n", [Status]),
            [];
        {error, Reason} ->
            io:format("[dbpedia] lookup failed: ~p~n", [Reason]),
            []
    end.

parse_lookup_response(Body) ->
    try json:decode(Body) of
        #{<<"docs">> := Docs} when is_list(Docs) ->
            [extract_hit(D) || D <- Docs];
        _ -> []
    catch
        _:_ -> []
    end.

%% Each doc has "resource" (list with URI) and optionally "comment".
extract_hit(Doc) ->
    Uri = case maps:get(<<"resource">>, Doc, []) of
        [U | _] -> U;
        _       -> undefined
    end,
    WikiUrl = maps:get(<<"wikidataId">>, Doc, undefined),
    %% Lookup gives a short comment, we'll try to get the full abstract next.
    Comment = case maps:get(<<"comment">>, Doc, []) of
        [C | _] -> C;
        _       -> undefined
    end,
    #{uri => Uri, wiki_url => WikiUrl, comment => Comment}.

%% Step 2: for each hit that has a URI, fetch the English abstract via SPARQL.
%% We batch all URIs in a single VALUES query to avoid N round-trips.
enrich_with_abstracts([], _Timeout) -> [];
enrich_with_abstracts(Hits, Timeout) ->
    Uris = [Uri || #{uri := Uri} <- Hits, Uri =/= undefined],
    AbstractMap = fetch_abstracts(Uris, Timeout),
    lists:filtermap(fun(#{uri := Uri, comment := Comment}) ->
        Abstract = maps:get(Uri, AbstractMap, Comment),
        WikiUrl  = uri_to_wiki(Uri),
        case {WikiUrl, Abstract} of
            {W, A} when is_binary(W), is_binary(A) ->
                {true, #{<<"properties">> => #{<<"url">> => W, <<"resume">> => A}}};
            _ ->
                false
        end
    end, Hits).

uri_to_wiki(Uri) when is_binary(Uri) ->
    %% http://dbpedia.org/resource/Apple_Inc -> https://en.wikipedia.org/wiki/Apple_Inc
    case binary:split(Uri, <<"/resource/">>) of
        [_, Name] ->
            <<"https://en.wikipedia.org/wiki/", Name/binary>>;
        _ ->
            undefined
    end;
uri_to_wiki(_) -> undefined.

fetch_abstracts([], _Timeout) -> #{};
fetch_abstracts(Uris, Timeout) ->
    Values  = string:join(
        [lists:flatten(io_lib:format("(<~s>)", [binary_to_list(U)])) || U <- Uris],
        " "),
    Query = lists:flatten(io_lib:format(
        "PREFIX dbo: <http://dbpedia.org/ontology/> "
        "SELECT ?s ?abstract WHERE { "
        "  VALUES (?s) { ~s } "
        "  ?s dbo:abstract ?abstract . "
        "  FILTER (langMatches(lang(?abstract), \"en\")) "
        "} LIMIT ~p",
        [Values, length(Uris)])),
    Params  = "query=" ++ uri_string:quote(Query),
    Headers = [{"Accept", "application/sparql-results+json"}],
    case httpc:request(post,
                       {?SPARQL_ENDPOINT, Headers,
                        "application/x-www-form-urlencoded", Params},
                       [{timeout, Timeout * 1000}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            parse_abstract_response(Body);
        _ ->
            #{}
    end.

parse_abstract_response(Body) ->
    try json:decode(Body) of
        Json ->
            case get_path(Json, [<<"results">>, <<"bindings">>]) of
                Bindings when is_list(Bindings) ->
                    lists:foldl(fun(B, Acc) ->
                        S = get_path(B, [<<"s">>,        <<"value">>]),
                        A = get_path(B, [<<"abstract">>, <<"value">>]),
                        case {S, A} of
                            {Su, Ab} when is_binary(Su), is_binary(Ab) ->
                                Acc#{Su => Ab};
                            _ -> Acc
                        end
                    end, #{}, Bindings);
                _ -> #{}
            end
    catch
        _:_ -> #{}
    end.

%%====================================================================
%% Helpers
%%====================================================================

extract_params(JsonBinary) ->
    try json:decode(JsonBinary) of
        Map when is_map(Map) ->
            Value = binary_to_list(maps:get(<<"value">>, Map, <<"">>)),
            Timeout = case maps:get(<<"timeout">>, Map, undefined) of
                undefined            -> 10;
                T when is_integer(T) -> T;
                T when is_binary(T)  -> binary_to_integer(T)
            end,
            TypeClass = binary_to_list(maps:get(<<"dbo">>, Map, <<"">>)),
            {Value, Timeout, TypeClass};
        _ ->
            {binary_to_list(JsonBinary), 10, ""}
    catch
        _:_ -> {binary_to_list(JsonBinary), 10, ""}
    end.

get_path(Json, []) -> Json;
get_path(Json, [Key | Rest]) when is_map(Json) ->
    case maps:find(Key, Json) of
        {ok, Value} -> get_path(Value, Rest);
        error       -> undefined
    end;
get_path(_, _) -> undefined.

-spec url_of(map()) -> binary().
url_of(#{<<"properties">> := #{<<"url">> := Url}}) -> Url;
url_of(_) -> <<>>.

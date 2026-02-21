%%%-------------------------------------------------------------------
%%% @doc DBpedia SPARQL filter.
%%%
%%% Queries the DBpedia SPARQL endpoint for entities matching the
%%% search value and returns their Wikipedia URL and abstract.
%%% @end
%%%-------------------------------------------------------------------
-module(dbpedia_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/1]).

-define(DBPEDIA_ENDPOINT, "https://dbpedia.org/sparql").

%%====================================================================
%% Application behaviour
%%====================================================================

start(_StartType, _StartArgs) ->
    em_filter:start_filter(dbpedia_filter, ?MODULE).

stop(_State) ->
    em_filter:stop_filter(dbpedia_filter).

%%====================================================================
%% Filter handler — returns a list of embryo maps
%%====================================================================

handle(Body) when is_binary(Body) ->
    generate_embryo_list(Body);
handle(_) ->
    [].

%%====================================================================
%% Search and processing
%%====================================================================

generate_embryo_list(JsonBinary) ->
    {Value, Timeout, Dbo} = extract_params(JsonBinary),
    Query = build_sparql_query(Value, Dbo),
    Params = "query=" ++ uri_string:quote(Query),
    Headers = [{"Accept", "application/sparql-results+json"}],
    StartTime = erlang:system_time(millisecond),
    case httpc:request(post,
                       {?DBPEDIA_ENDPOINT, Headers,
                        "application/x-www-form-urlencoded", Params},
                       [{timeout, Timeout * 1000}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            parse_dbpedia_response(Body, StartTime, Timeout * 1000);
        _ ->
            []
    end.

extract_params(JsonBinary) ->
    try json:decode(JsonBinary) of
        Map when is_map(Map) ->
            Value   = binary_to_list(maps:get(<<"value">>,   Map, <<"">>)),
            Timeout = case maps:get(<<"timeout">>, Map, undefined) of
                undefined            -> 10;
                T when is_integer(T) -> T;
                T when is_binary(T)  -> binary_to_integer(T)
            end,
            Dbo = binary_to_list(maps:get(<<"dbo">>, Map, <<"Company">>)),
            {Value, Timeout, Dbo};
        _ ->
            {binary_to_list(JsonBinary), 10, "Company"}
    catch
        _:_ -> {binary_to_list(JsonBinary), 10, "Company"}
    end.

build_sparql_query(Value, Dbo) ->
    lists:flatten(io_lib:format(
        "PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#> "
        "SELECT DISTINCT ?url ?abstract "
        "WHERE {{ "
        "  {{ "
        "    ?s a ?type ; "
        "      rdfs:label ?label ; "
        "      <http://dbpedia.org/ontology/abstract> ?abstract ; "
        "      foaf:isPrimaryTopicOf ?url . "
        "      FILTER (langMatches(lang(?abstract), \"en\")) "
        "      FILTER (contains(?label, \"~s\")) "
        "      FILTER (?type IN (<http://dbpedia.org/ontology/~s>)) "
        "  }} "
        "}} ", [Value, Dbo])).

%%--------------------------------------------------------------------
%% Response parsing
%%--------------------------------------------------------------------

parse_dbpedia_response(Body, StartTime, Timeout) ->
    try json:decode(Body) of
        Json ->
            case get_path(Json, [<<"results">>, <<"bindings">>]) of
                Bindings when is_list(Bindings) ->
                    process_bindings(Bindings, StartTime, Timeout, []);
                _ ->
                    []
            end
    catch
        _:_ -> []
    end.

process_bindings([], _StartTime, _Timeout, Acc) ->
    lists:reverse(Acc);
process_bindings([Binding | Rest], StartTime, Timeout, Acc) ->
    case erlang:system_time(millisecond) - StartTime >= Timeout of
        true  -> lists:reverse(Acc);
        false ->
            NewAcc = case process_binding(Binding) of
                {ok, Embryo} -> [Embryo | Acc];
                skip         -> Acc
            end,
            process_bindings(Rest, StartTime, Timeout, NewAcc)
    end.

process_binding(Binding) ->
    Url      = get_path(Binding, [<<"url">>,      <<"value">>]),
    Abstract = get_path(Binding, [<<"abstract">>, <<"value">>]),
    case {Url, Abstract} of
        {U, A} when is_binary(U), is_binary(A) ->
            {ok, #{
                <<"properties">> => #{
                    <<"url">>    => U,
                    <<"resume">> => A
                }
            }};
        _ -> skip
    end.

%% Safely traverses a nested map structure.
get_path(Json, []) -> Json;
get_path(Json, [Key | Rest]) when is_map(Json) ->
    case maps:find(Key, Json) of
        {ok, Value} -> get_path(Value, Rest);
        error       -> undefined
    end;
get_path(_, _) -> undefined.

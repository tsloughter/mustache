%% @copyright 2015 Hinagiku Soranoba All Rights Reserved.
%%
%% @doc Mustach template engine for Erlang/OTP.
-module(mustache).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

%%----------------------------------------------------------------------------------------------------------------------
%% Exported API
%%----------------------------------------------------------------------------------------------------------------------
-export([
         new/1,
         parse_file/1,
         compile/2
        ]).

-export_type([
              template/0
             ]).

%%----------------------------------------------------------------------------------------------------------------------
%% Defines & Records & Types
%%----------------------------------------------------------------------------------------------------------------------

-define(PARSE_ERROR, incorrect_format).
-define(FILE_ERROR, file_not_found).
-define(COND(Cond, TValue, FValue),
        case Cond of true -> TValue; false -> FValue end).

-type key()  :: binary().
-type tag()  :: {n,   key()}          |
                {'&', key()}          |
                {'#', key(), [tag()]} |
                {'^', key(), [tag()]} |
                {'>', key()}          |
                binary().
-type partial() :: {partial, {EndTag :: binary(), Rest :: binary(), [tag()]}}.

-record(state,
        {
          dirname = <<>>     :: filename:filename_all(),
          start   = <<"{{">> :: binary(),
          stop    = <<"}}">> :: binary()
        }).
-type state() :: #state{}.

-record(?MODULE,
        {
          data :: [tag()]
        }).

-opaque template() :: #?MODULE{}.
-type data()     :: #{string() => data() | iodata() | fun((data(), function()) -> iodata())}.

%%----------------------------------------------------------------------------------------------------------------------
%% Exported Functions
%%----------------------------------------------------------------------------------------------------------------------

%% @doc
-spec new(binary()) -> template().
new(Bin) when is_binary(Bin) ->
    new_impl(#state{}, Bin).

%% @doc
-spec parse_file(file:filename()) -> template().
parse_file(Filename) ->
    case file:read_file(Filename) of
        {ok, Bin} -> new_impl(#state{dirname = filename:dirname(Filename)}, Bin);
        _         -> error(?FILE_ERROR, [Filename])
    end.

%% @doc
-spec compile(template(), data()) -> binary().
compile(#?MODULE{}, Map) when is_map(Map) ->
    hoge.

%%----------------------------------------------------------------------------------------------------------------------
%% Internal Function
%%----------------------------------------------------------------------------------------------------------------------

%% @see new/1
-spec new_impl(state(), Input :: binary()) -> template().
new_impl(State, Input) ->
    #?MODULE{data = parse(State, Input)}.

%% @doc
-spec parse(state(), binary()) -> [tag()].
parse(State, Bin) ->
    case parse1(State, Bin, []) of
        {partial, _} -> error(?PARSE_ERROR);
        {_, Tags}    -> lists:reverse(Tags)
    end.

%% @doc Part of the `parse/1'
%%
%% ATTENTION: The result is a list that is inverted.
-spec parse1(state(), Input :: binary(), Result :: [tag()]) -> {state(), [tag()]} | partial().
parse1(#state{start = Start, stop = Stop} = State, Bin, Result) ->
    case binary:split(Bin, Start) of
        []                       -> {State, Result};
        [B1]                     -> {State, [B1 | Result]};
        [B1, <<"{", B2/binary>>] -> parse2(State, binary:split(B2, <<"}", Stop/binary>>), [B1 | Result]);
        [B1, B2]                 -> parse3(State, binary:split(B2, Stop),                 [B1 | Result])
    end.

%% @doc Part of the `parse/1'
%%
%% ATTENTION: The result is a list that is inverted.
parse2(State, [B1, B2], Result) ->
    parse1(State, B2, [{'&', remove_space_from_edge(B1)} | Result]);
parse2(_, _, _) ->
    error(?PARSE_ERROR).

%% @doc Part of the `parse/1'
%%
%% ATTENTION: The result is a list that is inverted.
parse3(State, [B1, B2], Result) ->
    case remove_space_from_head(B1) of
        <<"&", Tag/binary>> ->
            parse1(State, B2, [{'&', remove_space_from_edge(Tag)} | Result]);
        <<T, Tag/binary>> when T =:= $#; T =:= $^ ->
            parse_loop(State, ?COND(T =:= $#, '#', '^'), remove_space_from_edge(Tag), B2, Result);
        <<"=", Tag0/binary>> ->
            Tag1 = remove_space_from_tail(Tag0),
            Size = byte_size(Tag1) - 1,
            case Size >= 0 andalso Tag1 of
                <<Tag2:Size/binary, "=">> -> parse_delimiter(State, Tag2, B2, Result);
                _                         -> error(?PARSE_ERROR)
            end;
        <<"!", _/binary>> ->
            parse1(State, B2, Result);
        <<"/", Tag/binary>> ->
            {partial, {State, remove_space_from_edge(Tag), B2, Result}};
        <<">", Tag/binary>> ->
            parse_jump(State, remove_space_from_edge(Tag), B2, Result);
        Tag ->
            parse1(State, B2, [{n, remove_space_from_tail(Tag)} | Result])
    end;
parse3(_, _, _) ->
    error(?PARSE_ERROR).

%% @doc Loop processing part of the `parse/1'
%%
%% `{{# Tag}}' or `{{^ Tag}}' corresponds to this.
-spec parse_loop(state(), '#' | '^', Tag :: binary(), Input :: binary(), Result :: [tag()]) -> [tag()] | partial().
parse_loop(State0, Mark, Tag, Input, Result0) ->
    case parse1(State0, Input, []) of
        {partial, {State, Tag, Rest, Result1}} when is_list(Result1) ->
            parse1(State, Rest, [{Mark, Tag, lists:reverse(Result1)} | Result0]);
        _ ->
            error(?PARSE_ERROR)
    end.

%% @doc Partial part of the `parse/1'
-spec parse_jump(state(), Tag :: binary(), NextBin :: binary(), Result :: [tag()]) -> [tag()] | partial().
parse_jump(#state{dirname = Dirname} = State0, Tag, NextBin, Result0) ->
    Filename = filename:join(?COND(Dirname =:= <<>>, [Tag], [Dirname, Tag])),
    case file:read_file(Filename) of
        {ok, Bin} ->
            case parse1(State0, Bin, Result0) of
                {partial, _}    -> error(?PARSE_ERROR);
                {State, Result} -> parse1(State, NextBin, Result)
            end;
        _ ->
            error(?FILE_ERROR, [Filename])
    end.

%% @doc Update delimiter part of the `parse/1'
%%
%% NewDelimiterBin :: e.g. `{{=%% %%=}}' -> `%% %%'
-spec parse_delimiter(state(), NewDelimiterBin :: binary(), NextBin :: binary(), Result :: [tag()]) -> [tag()] | partial().
parse_delimiter(State0, NewDelimiterBin, NextBin, Result) ->
    case binary:match(NewDelimiterBin, <<"=">>) of
        nomatch ->
            case [X || X <- binary:split(NewDelimiterBin, <<" ">>, [global]), X =/= <<>>] of
                [Start, Stop] -> parse1(State0#state{start = Start, stop = Stop}, NextBin, Result);
                _             -> error(?PARSE_ERROR)
            end;
        _ ->
            error(?PARSE_ERROR)
    end.

%% @doc Remove the space from the edge.
-spec remove_space_from_edge(binary()) -> binary().
remove_space_from_edge(Bin) ->
    remove_space_from_tail(remove_space_from_head(Bin)).

%% @doc Remove the space from the head.
-spec remove_space_from_head(binary()) -> binary().
remove_space_from_head(<<" ", Rest/binary>>) -> remove_space_from_head(Rest);
remove_space_from_head(Bin)                  -> Bin.

%% @doc Remove the space from the tail.
-spec remove_space_from_tail(binary()) -> binary().
remove_space_from_tail(<<>>) -> <<>>;
remove_space_from_tail(Bin) ->
    PosList = binary:matches(Bin, <<" ">>),
    LastPos = remove_space_from_tail_impl(lists:reverse(PosList), byte_size(Bin)),
    binary:part(Bin, 0, LastPos).

%% @see remove_space_from_tail/1
-spec remove_space_from_tail_impl([{non_neg_integer(), pos_integer()}], non_neg_integer()) -> non_neg_integer().
remove_space_from_tail_impl([{X, Y} | T], Size) when Size =:= X + Y ->
    remove_space_from_tail_impl(T, X);
remove_space_from_tail_impl(_, Size) ->
    Size.

%%----------------------------------------------------------------------------------------------------------------------
%% Unit Tests
%%----------------------------------------------------------------------------------------------------------------------

-ifdef(TEST).

-define(NT_S(X, Y), ?_assertEqual(#?MODULE{data=X}, ?MODULE:new(Y))).
%% new_test generater (success case)
-define(NT_F(X),    ?_assertError(_,                ?MODULE:new(X))).
%% new_test generater (failure case)

new_test_() ->
    [
     {"{{tag}}",     ?NT_S([<<"a">>, {n, <<"t">>}, <<"b">>],   <<"a{{t}}b">>)},
     {"{{ tag }}",   ?NT_S([<<>>, {n, <<"t">>}, <<>>],         <<"{{ t }}">>)},
     {"{{ ta g }}",  ?NT_S([<<>>, {n, <<"ta g">>}, <<>>],      <<"{{ ta g }}">>)},

     {"{{{tag}}}",   ?NT_S([<<"a">>, {'&', <<"t">>}, <<"b">>], <<"a{{{t}}}b">>)},
     {"{{{ tag }}}", ?NT_S([<<>>, {'&', <<"t">>}, <<>>],       <<"{{{ t }}}">>)},
     {"{{{ ta g }}}",?NT_S([<<>>, {'&', <<"ta g">>}, <<>>],    <<"{{{ ta g }}}">>)},

     {"{{& tag}}",   ?NT_S([<<"a">>, {'&', <<"t">>}, <<"b">>], <<"a{{& t}}b">>)},
     {"{{ & tag }}", ?NT_S([<<>>, {'&', <<"t">>}, <<>>],       <<"{{ & t }}">>)},
     {"{{ & ta g }}",?NT_S([<<>>, {'&', <<"ta g">>}, <<>>],    <<"{{ & ta g }}">>)},
     {"{{&ta g }}",  ?NT_S([<<>>, {'&', <<"ta g">>}, <<>>],    <<"{{&ta g}}">>)},
     {"{{&tag}}",    ?NT_S([<<>>, {'&', <<"t">>}, <<>>],       <<"{{&t}}">>)},

     {"{{#tag}}",    ?NT_F(<<"{{#tag}}">>)},
     {"{{#tag1}}{{#tag2}}{{name}}{{/tag1}}{{/tag2}}",
      ?NT_S([<<"a">>, {'#', <<"t1">>, [<<"b">>, {'#', <<"t2">>, [<<"c">>, {n, <<"t3">>}, <<"d">>]}, <<"e">>]}, <<"f">>],
            <<"a{{#t1}}b{{#t2}}c{{t3}}d{{/t2}}e{{/t1}}f">>)},
     {"{{#tag1}}{{#tag2}}{{/tag1}}{{/tag2}}", ?NT_F(<<"{{#t1}}{{#t2}}{{/t1}}{{/t2}}">>)},

     {"{{# tag}}{{/ tag}}",     ?NT_S([<<>>, {'#', <<"tag">>, [<<>>]}, <<>>],  <<"{{# tag}}{{/ tag}}">>)},
     {"{{ #tag }}{{ / tag }}",  ?NT_S([<<>>, {'#', <<"tag">>, [<<>>]}, <<>>],  <<"{{ #tag }}{{ / tag }}">>)},
     {"{{ # tag }}{{ /tag }}",  ?NT_S([<<>>, {'#', <<"tag">>, [<<>>]}, <<>>],  <<"{{ # tag }}{{ /tag }}">>)},
     {"{{ # ta g}}{{ / ta g}}", ?NT_S([<<>>, {'#', <<"ta g">>, [<<>>]}, <<>>], <<"{{ # ta g}}{{ / ta g}}">>)},

     {"{{!comment}}",           ?NT_S([<<"a">>, <<"c">>], <<"a{{!comment}}c">>)},
     {"{{! comment }}",         ?NT_S([<<>>, <<>>],       <<"{{! comment }}">>)},
     {"{{! co mmen t }}",       ?NT_S([<<>>, <<>>],       <<"{{! co mmen t }}">>)},
     {"{{ !comment }}",         ?NT_S([<<>>, <<>>],       <<"{{ !comment }}">>)},

     {"{{^tag}}",    ?NT_F(<<"a{{^tag}}b">>)},
     {"{{^tag1}}{{^tag2}}{{name}}{{/tag2}}{{/tag1}}",
      ?NT_S([<<"a">>, {'^', <<"t1">>, [<<"b">>, {'^', <<"t2">>, [<<"c">>, {n, <<"t3">>}, <<"d">>]}, <<"e">>]}, <<"f">>],
            <<"a{{^t1}}b{{^t2}}c{{t3}}d{{/t2}}e{{/t1}}f">>)},
     {"{{^tag1}}{{^tag2}}{{/tag1}}{{tag2}}", ?NT_F(<<"{{^t1}}{{^t2}}{{/t1}}{{/t2}}">>)},

     {"{{^ tag}}{{/ tag}}",     ?NT_S([<<>>, {'^', <<"tag">>,  [<<>>]}, <<>>], <<"{{^ tag}}{{/ tag}}">>)},
     {"{{ ^tag }}{{ / tag }}",  ?NT_S([<<>>, {'^', <<"tag">>,  [<<>>]}, <<>>], <<"{{ ^tag }}{{ / tag }}">>)},
     {"{{ ^ tag }}{{ /tag }}",  ?NT_S([<<>>, {'^', <<"tag">>,  [<<>>]}, <<>>], <<"{{ ^ tag }}{{ /tag }}">>)},
     {"{{ ^ ta g}}{{ / ta g}}", ?NT_S([<<>>, {'^', <<"ta g">>, [<<>>]}, <<>>], <<"{{ ^ ta g}}{{ / ta g}}">>)},

     {"{{=<< >>=}}{{n}}<<n>><<={{ }}=>>{{n}}<<n>>",
      ?NT_S([<<"a">>, <<"b{{n}}c">>, {n, <<"n">>}, <<"d">>, <<"e">>, {n, <<"m">>}, <<"f<<m>>g">>],
            <<"a{{=<< >>=}}b{{n}}c<<n>>d<<={{ }}=>>e{{m}}f<<m>>g">>)},
     {"{{=<< >>=}}<<#tag>><<{n}>><</tag>>",
      ?NT_S([<<>>, <<>>, {'#', <<"tag">>, [<<>>, {'&', <<"n">>}, <<>>]}, <<>>], <<"{{=<< >>=}}<<#tag>><<{n}>><</tag>>">>)},

     {"{{=<<  >>=}}<<n>>",      ?NT_S([<<>>, <<>>, {n, <<"n">>}, <<>>], <<"{{=<<  >>=}}<<n>>">>)},
     {"{{ = << >> = }}<<n>>",   ?NT_S([<<>>, <<>>, {n, <<"n">>}, <<>>], <<"{{ = << >> = }}<<n>>">>)},
     {"{{=<= =>=}}<=n=>",       ?NT_F(<<"{{=<= =>=}}<=n=>">>)},
     {"{{ = < < >> = }}< <n>>", ?NT_F(<<"{{ = < < >> = }}< <n>>">>)}
    ].

-endif.
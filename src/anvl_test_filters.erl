%%--------------------------------------------------------------------
%% Copyright (c) 2025-2026 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------
-module(anvl_test_filters).

%% API:
-export([passes/4, by_runner/1, by_suite/1, by_testcase/1, by_tags/2]).

-export_type([spec/0]).

-include("anvl_test_internal.hrl").

%%================================================================================
%% Types
%%================================================================================

-doc """
Specification of a test case filter.

A filter spec is a tuple of a fun and an arbitrary configuration value.
The fun takes the following arguments:

@enumerate
@item the runner module
@item the suite
@item the @code{#tc@{@}} record of the test case
@item the configuration value of the spec
@item the current boolean value of the accumulator
@end enumerate

It returns the next value of the accumulator.

A test case is executed when folding the filter specs of @erlfn{ref,erlref,anvl_test,run_suite,2}
over the accumulator from left to right,
starting with @code{true},
yields @code{true}.
""".
-type spec() ::
        { fun(( Runner :: module()
              , Suite  :: #suite{}
              , TC     :: #tc{}
              , Conf   :: term()
              , Acc    :: boolean()
              ) -> boolean())
        , Conf :: term()
        }.

%%================================================================================
%% API functions
%%================================================================================

-spec by_runner(anvl_test:runner() | {all}) -> spec().
by_runner(Runner) ->
  {fun filter_runner/5, Runner}.

-spec by_suite(anvl_test:suite() | {all}) -> spec().
by_suite(Suite) ->
  {fun filter_suite/5, Suite}.

-spec by_testcase(anvl_test:testcase() | {all}) -> spec().
by_testcase(Testcase) ->
  {fun filter_testcase/5, Testcase}.

-spec by_tags([anvl_test:tag()] | {all}, [anvl_test:tag()]) -> spec().
by_tags(Include, Exclude) ->
  {fun filter_by_tag/5, {Include, Exclude}}.

-spec passes(module(), #suite{}, #tc{}, [spec()]) -> boolean().
passes(Runner, Suite, TC, Filters) ->
  lists:foldl(fun({Fun, Conf}, Acc) -> Fun(Runner, Suite, TC, Conf, Acc) end,
              true,
              Filters).

%%================================================================================
%% Internal functions
%%================================================================================

filter_runner(_Runner, _Suite, _TC, {all}, Acc) ->
  Acc;
filter_runner(Runner, _Suite, _TC, Conf, Acc) ->
  Acc andalso Runner =:= Conf.

filter_suite(_Runner, _Suite, _TC, {all}, Acc) ->
  Acc;
filter_suite(_Runner, #suite{suite = Suite}, _TC, Conf, Acc) ->
  Acc andalso Suite =:= Conf.

filter_testcase(_Runner, _Suite, _TC, {all}, Acc) ->
  Acc;
filter_testcase(_Runner, _Suite, #tc{name = Name}, Conf, Acc) ->
  Acc andalso Name =:= Conf.

filter_by_tag(_Runner, #suite{tags = STags}, #tc{tags = TCTags}, {Include, Exclude}, Acc) ->
  Tags = ordsets:from_list(STags ++ TCTags),
  Acc andalso
    case Include of
      {all} ->
        true;
      _ ->
        not ordsets:is_disjoint(
              ordsets:from_list(Include),
              Tags)
    end
    andalso
    ordsets:is_disjoint(
      ordsets:from_list(Exclude),
      Tags).

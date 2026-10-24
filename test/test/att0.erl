-ifdef(TEST).

-module(att0).
-behavior(anvl_test_suite).

-moduledoc """
Test suite that doesn't have any global tags or fixtures.
""".

-include_lib("anvl_test/include/anvl_test.hrl").
-include_lib("stdlib/include/assert.hrl").

-include_lib("kernel/include/logger.hrl").

%% Fixture with the code paths of the closure of the test application:
-define(CODE_PATH_FIXTURE, anvl_test:code_path_fixture(anvl_project:root(), test, anvl_test_test)).

%% Override a fixture that anvl_test sets itself, to check the warning:
-export([fixtures/0]).
fixtures() ->
  [ ?CODE_PATH_FIXTURE
  , {familiar_workdir, #{}}
  ].

-test(foo).
foo(instances, _) ->
  [1, 2];
foo(tags, #{instance := Inst}) ->
  case Inst of
    1 -> [tag_1];
    2 -> [tag_2]
  end;
foo(timeout, #{instance := 1}) ->
  1000;
foo(run, #{instance := Instance, familiar := #{net := Net, subnet := 24}}) ->
  ?LOG_NOTICE("Hello from foo! ~p", [Instance]),
  check_subnet(Net).

-test(parent_node_is_hidden).
parent_node_is_hidden(run, #{instance := _, familiar := #{net := Net, subnet := 24}}) ->
  check_subnet(Net),
  ?assertMatch([], nodes());
parent_node_is_hidden(crash, Env) ->
  %% This branch should be unreachable
  error(Env).

%% Create a nested cluster using the anvl_test_cluster fixture:
-test(cluster).
cluster(fixtures, #{instance := default}) ->
  [ ?CODE_PATH_FIXTURE
  , {anvl_test_cluster, #{}}
  ];
cluster(run, #{instance := default, familiar := #{net := Net, subnet := 24}}) ->
  Cluster = anvl_test_cluster:get_cluster(),
  {ok, Site} = familiar:create_site(Cluster, site1),
  {ok, Node} = familiar:start_site(Site),
  %% The nested cluster occupies its own network, derived from the
  %% network settings of the test case:
  ?assertEqual(
     "site1@127." ++ integer_to_list(Net) ++ ".0.0",
     atom_to_list(Node)),
  ?assertEqual(Node, familiar:call(Site, erlang, node, [])),
  %% The ID of the cluster is in the fixture state of the node:
  ?assertMatch(
     #{test_cluster := Cluster},
     familiar:fixture_state()).

%% Each instance of the test case spawns a nested cluster of its own,
%% with a few sites in it:
-test(multi_site_cluster).
multi_site_cluster(instances, _) ->
  [1, 2];
multi_site_cluster(fixtures, #{instance := _}) ->
  [ ?CODE_PATH_FIXTURE
  , {anvl_test_cluster, #{}}
  ];
multi_site_cluster(run, #{instance := _, familiar := #{net := Net, subnet := 24}}) ->
  Cluster = anvl_test_cluster:get_cluster(),
  %% Each site occupies its own address in the 127.Net.0.0/24 network
  %% of the cluster:
  Sites = [ {Site, Node}
          || Id <- [site1, site2, site3]
          , {ok, Site, Node} <- [familiar:create_site(Cluster, Id, #{start => true})]
          ],
  ?assertEqual(
     [atom_to_list(Id) ++ "@127." ++ integer_to_list(Net) ++ ".0." ++ integer_to_list(Octet)
     || {Id, Octet} <- [{site1, 0}, {site2, 1}, {site3, 2}]
     ],
     [atom_to_list(Node) || {_Site, Node} <- Sites]),
  lists:foreach(
    fun({Site, Node}) ->
        ?assertEqual(Node, familiar:call(Site, erlang, node, []))
    end,
    Sites),
  %% The sites are connected to each other, and to the test node that
  %% started them:
  [{Site1, _} | Rest] = Sites,
  lists:foreach(
    fun({_, Node}) ->
        pong = familiar:call(Site1, net_adm, ping, [Node])
    end,
    Rest),
  ?assertEqual(
     lists:sort([Node || {_, Node} <- Rest]),
     lists:sort(familiar:call(Site1, erlang, nodes, []))).

-test(expected_fail).
expected_fail(run, #{instance := _, familiar := _}) ->
  error(expected_fail).

%% This test case is expected to time out:
-test(sleepy).
sleepy(timeout, #{instance := _}) ->
  200;
sleepy(run, #{instance := _, familiar := _}) ->
  receive after infinity -> ok end.

%% Assert that the network number passed in the environment matches the
%% address of the test node:
check_subnet(Net) ->
  [_, Host] = string:split(atom_to_list(node()), "@"),
  [_, _, Octet3, _] = string:split(Host, ".", all),
  ?assertEqual(Net, list_to_integer(Octet3)),
  ok.

-endif.

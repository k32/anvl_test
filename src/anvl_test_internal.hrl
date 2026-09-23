%%--------------------------------------------------------------------
%% Copyright (c) 2025-2026 EMQ Technologies Co., Ltd. All Rights Reserved.
%%--------------------------------------------------------------------
-ifndef(ANVL_TEST_INTERNAL_HRL).
-define(ANVL_TEST_INTERNAL_HRL, true).

-record(filter,
        { include = all :: [anvl_test_suite:tag()] | all
        , exclude = []  :: [anvl_test_suite:tag()]
        }).

-record(tc,
        { name :: atom()
        , inst :: anvl_test_suite:instance()
        , tags :: list()
        , fixtures :: [anvl_test_suite:fixture()]
        }).

-record(suite,
        { mod :: module()
        , tests :: [anvl_test_suite:test()]
        , fixtures :: [familiar:fixture()]
        , tags :: list()
        , tcs :: [#tc{}]
        }).

-endif.

-ifndef(ANVL_TEST_INTERNAL_HRL).
-define(ANVL_TEST_INTERNAL_HRL, true).

-record(tc,
        { name :: atom()
        , inst :: anvl_test_suite:instance()
        , tags :: list()
        , fixtures :: [anvl_test_suite:fixture()]
        , timeout :: timeout()
        }).

-record(tc_error,
        { class :: throw | exit | error | timeout
        , reason :: term()
        , stack :: list()
        }).

-record(suite,
        { suite :: anvl_test:suite()
        , runner = anvl_test_suite :: module()
        , runner_options
        , tests :: [anvl_test_suite:test()]
        , fixtures :: [familiar:fixture()]
        , tags :: list()
        , tcs :: [#tc{}]
        }).

-endif.

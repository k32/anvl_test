-ifndef(ANVL_TEST_INTERNAL_HRL).
-define(ANVL_TEST_INTERNAL_HRL, true).

-record(tc,
        { name :: anvl_test:testcase()
        , inst :: anvl_test:instance()
        , tags :: [anvl_test:tag()]
        , fixtures :: [anvl_test:fixture()]
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
        , fixtures :: [familiar:fixture()]
        , tags :: [anvl_test:tag()]
        , tcs :: [#tc{}]
        }).

-endif.

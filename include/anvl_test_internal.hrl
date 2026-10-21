-ifndef(ANVL_TEST_INTERNAL_HRL).
-define(ANVL_TEST_INTERNAL_HRL, true).

-record(tc,
        { name :: atom()
        , inst :: anvl_test_suite:instance()
        , tags :: list()
        , fixtures :: [anvl_test_suite:fixture()]
        }).

-record(suite,
        { suite :: anvl_test:suite()
        , runner = anvl_test_suite :: module()
        , tests :: [anvl_test_suite:test()]
        , fixtures :: [familiar:fixture()]
        , tags :: list()
        , tcs :: [#tc{}]
        }).

-endif.

-include("anvl.hrl").

conf() ->
  #{ plugins => [anvl_erlc, anvl_git, anvl_texinfo, anvl_rebar3]
   , conditions => [build, static_checks]
   , [erlang, includes] => ["${src_root}/include", "${src_root}/src", anvl_plugin:includes_dir()]
   , [deps, git] =>
       [#{ id => familiar
         , repo => "https://github.com/ieQu1/familiar.git"
         , ref => {tag, "0.1.4"}
         }]
   , [erlang, static_checks] =>
       #{ non_runtime_deps => [anvl_core, lee, typerefl]
        }
   , texinfo =>
       #{ compile =>
            [#{ format => html
              , options => ["-c", "INFO_JS_DIR=js"]
              }
            ]
        , formats => [info, html]
        , sources => ["doc/anvl_test.texi"]
        , include_dirs => [anvl_texinfo_erlang:includes_dir()]
        }
   }.

?MEMO(build,
      precondition(
        [ anvl_erlc:app_compiled(default, anvl_test)
        , doc()
        ])).

?MEMO(static_checks,
      precondition(
        [ anvl_erlc_xref:passed(default)
        , anvl_erlc_dialyzer:passed(default)
        ])).

?MEMO(doc,
      begin
        precondition(anvl_texinfo:anvl_plugin_documented(anvl_test)) or
        precondition(anvl_texinfo:compiled(anvl_project:root()))
      end).

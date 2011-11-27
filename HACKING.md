HACKING
=======

Trap/Error handling
-------------------

Traps and error handling is handled by ERR trap handlers.
To perform local cleanups on functions, do something like this

    function my_function() {
        function my_function_cleanup() {
            # do cleanup here
            return 1
        }

        trap "my_function; return 1" ERR SIGINT SIGTERM
    }

In particular, don't restore or muck with trap handlers, don't set -e
mode, and make sure to return 1 to allow the upstream trap handler to
fire -- that's how the trap handlers nest.  Don't handle EXIT error.
The global exit handler will take care of exit.

If you want to abort early and not fire the error exit trap handler
(log dumpage, etc), call handle_exit <retval> to exit with a return
value of retval.

In examples/code/trap_test.sh is a simplified model of the trap
handler.  You can play with that to see how it works.  If there is a
better model for allowing traps to bubble up, let me know, I'd be
interested to see a better way to handle nested traps.

Variables
---------

All functions should take all necessary arguments, and use only local
variables.  Local variables should be named with lower case.  Global
variables are set by the init() function or on the environment, from
context loading when working on an instance, or by the fakecloud
wrapper.  Treat globals as read-only.  Don't do crazy shit like change
them out from under things.  That way lies madness.




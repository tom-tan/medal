/**
 * Authors: Tomoya Tanjo
 * Copyright: © 2020 Tomoya Tanjo
 * License: Apache-2.0
 */
module medal.transition.shell;

import medal.config : Config;
import medal.logger : Logger, sharedLog;
import medal.transition.core;

import std.concurrency : Tid;
import std.json : JSONValue;
import std.range : empty;

version(unittest)
shared static this()
{
    import medal.logger : LogLevel;
    sharedLog.logLevel = LogLevel.off;
}

///
immutable class ShellCommandTransition_: Transition
{
    ///
    this(string name, string cmd, in Guard guard, in ArcExpressionFunction aef) @nogc nothrow pure @safe
    in(!cmd.empty)
    do
    {
        super(name, guard, aef);
        command = cmd;
    }

    ///
    protected override void fire(in BindingElement be, Tid networkTid, Config con = Config.init, Logger logger = sharedLog)
    {
        import medal.message : SignalSent, TransitionFailed, TransitionSucceeded;
        import std.algorithm : canFind, either;
        import std.concurrency : receive, send, spawn;
        import std.file : getcwd, remove;
        import std.process : Pid, spawnShell, tryWait;
        import std.stdio : File, stdin;
        import std.variant : Variant;

        logger.info(startMsg(be, con));
        scope(failure) logger.critical(failureMsg(be, con, "unknown error"));

        auto tmpdir = either(con.tmpdir, getcwd);
        auto needStdout = arcExpFun.byValue.canFind!(p => p.pattern == SpecialPattern.Stdout);
        File sout;
        if (needStdout)
        {
            import std.path : buildPath;
            import std.uuid : randomUUID;

            auto fname = randomUUID.toString;
            sout = File(buildPath(tmpdir, fname), "w");
        }
        else
        {
            import std.stdio : stdout;
            sout = stdout;
        }

        auto needStderr = arcExpFun.byValue.canFind!(p => p.pattern == SpecialPattern.Stderr);
        File serr;
        if (needStderr)
        {
            import std.path : buildPath;
            import std.uuid : randomUUID;
            auto fname = randomUUID.toString;
            serr = File(buildPath(tmpdir, fname), "w");
        }
        else
        {
            import std.stdio : stderr;
            serr = stderr;
        }
        
        auto needReturn = arcExpFun.byValue.canFind!(p => p.pattern == SpecialPattern.Return);

        auto cmd = commandWith(command, be);
        auto pid = spawnShell(cmd, stdin, sout, serr);

		spawn((shared Pid pid) {
            import std.concurrency : ownerTid;
            import std.process : wait;
            try 
            {
                // Note: if interrupted, it returns negative number
    			auto code = wait(cast()pid);
	    		send(ownerTid, code);
            }
            catch(Exception e)
            {
                send(ownerTid, cast(shared)e);
            }
		}, cast(shared)pid);

        auto result2BE(int code)
        {
            CommandResult result;
            result.code = code;
            if (needStdout)
            {
                result.stdout = sout.name;
            }
            if (needStderr)
            {
                result.stderr = serr.name;
            }
            return arcExpFun.apply(be, result);
        }

        receive(
            (int code) {
                auto ret = result2BE(code);
                if (needReturn || code == 0)
                {
                    logger.info(successMsg(be, ret, con));
                    send(networkTid,
                         TransitionSucceeded(ret));
                }
                else
                {
                    auto msg = "command returned with non-zero";
                    logger.info(failureMsg(be, con, msg));
                    send(networkTid,
                         TransitionFailed(be, msg));
                }
            },
            (in SignalSent sig) {
                import std.concurrency : receiveOnly;
                import std.format : format;
                import std.process : kill;

                kill(pid);
                receiveOnly!int;
                auto msg = format!"interrupted (%s)"(sig.no);
                logger.info(failureMsg(be, con, msg));
                send(networkTid,
                     TransitionFailed(be, msg));
            },
            (Variant v) {
                import std.concurrency : receiveOnly;
                import std.format : format;
                import std.process : kill;

                kill(pid);
                receiveOnly!int;

                auto msg = format!"unknown message (%s)"(v);
                logger.critical(failureMsg(be, con, msg));
                send(networkTid, TransitionFailed(be, msg));
            }
        );
        assert(tryWait(pid).terminated);
    }

    version(Posix)
    unittest
    {
        import medal.message : TransitionSucceeded;
        import std.concurrency : receive, thisTid;
        import std.variant : Variant;

        auto sct = new ShellCommandTransition("", "true", Guard.init,
                                              ArcExpressionFunction.init);
        spawnFire(sct, new BindingElement, thisTid);
        receive(
            (TransitionSucceeded ts) {
                assert(ts.tokenElements.empty);
            },
            (Variant v) { assert(false); },
        );
    }

    version(Posix)
    unittest
    {
        import medal.message : TransitionFailed;
        import std.concurrency : receive, thisTid;
        import std.variant : Variant;

        auto sct = new ShellCommandTransition("", "false", Guard.init,
                                              ArcExpressionFunction.init);
        spawnFire(sct, new BindingElement, thisTid);
        receive(
            (TransitionFailed tf) {
                assert(tf.tokenElements.empty);
            },
            (Variant v) { assert(false); },
        );
    }

    ///
    version(Posix)
    unittest
    {
        import medal.message : TransitionSucceeded;
        import std.concurrency : receive, thisTid;
        import std.conv : to;
        import std.variant : Variant;

        immutable aef = [
            Place("foo"): OutputPattern(SpecialPattern.Return),
        ];
        auto sct = new ShellCommandTransition("", "true", Guard.init, aef);
        spawnFire(sct, new BindingElement, thisTid);
        receive(
            (TransitionSucceeded ts) {
                assert(ts.tokenElements == [Place("foo"): new Token("0")]);
            },
            (Variant v) { assert(false, "Caught: "~v.to!string); },
        );
    }

    unittest
    {
        import medal.message : TransitionSucceeded;
        import std.concurrency : receive, thisTid;
        import std.variant : Variant;

        immutable aef = [
            Place("foo"): OutputPattern(SpecialPattern.Stdout),
        ];
        auto sct = new ShellCommandTransition("", "echo bar", Guard.init, aef);
        spawnFire(sct, new BindingElement, thisTid);
        receive(
            (TransitionSucceeded ts) {
                if (auto token = Place("foo") in ts.tokenElements.tokenElements)
                {
                    auto name = token.value;
                    import std.file : exists, readText, remove;
                    assert(name.exists);
                    scope(exit) name.remove;
                    assert(name.readText == "bar\n");
                }
                else
                {
                    assert(false);
                }
            },
            (Variant v) { assert(false); },
        );
    }

    version(Posix)
    unittest
    {
        import core.sys.posix.signal: SIGINT;
        import medal.message : SignalSent, TransitionFailed;
        import std.concurrency : receiveTimeout, send, thisTid;
        import std.datetime : seconds;
        import std.variant : Variant;

        immutable aef = [
            Place("foo"): OutputPattern(SpecialPattern.Return),
        ];
        auto sct = new ShellCommandTransition("", "sleep infinity", Guard.init, aef);
        auto tid = spawnFire(sct, new BindingElement, thisTid);
        send(tid, SignalSent(SIGINT));
        auto received = receiveTimeout(30.seconds,
            (TransitionFailed tf) {
                import std.format : format;
                auto expected = format!"interrupted (%s)"(SIGINT);
                assert(tf.cause == expected,
                       format!"`%s` is expected but: `%s`"(expected, tf.cause));
                assert(tf.tokenElements.empty);
            },
            (Variant v) { assert(false); },
        );
        assert(received);
    }
private:
    static string commandWith(in string cmd, in BindingElement be) pure @safe
    {
        import std.algorithm : findSplitAfter;
        import std.conv : to;

        enum escape = '~';

        auto aa = be.tokenElements.to!(string[string]);
        string str = cmd;
        string resulted;
        do
        {
            if (auto split = str.findSplitAfter([escape]))
            {
                resulted ~= split[0][0..$-1];
                auto rest = split[1];
                if (rest.empty)
                {
                    assert(false, "Invalid escape at the end of string");
                }

                switch(rest[0])
                {
                case escape:
                    resulted ~= escape;
                    str = rest[1..$];
                    break;
                case '(':
                    if (auto sp = rest[1..$].findSplitAfter(")"))
                    {
                        if (auto val = sp[0][0..$-1] in aa)
                        {
                            resulted ~= *val;
                            str = sp[1][0..$];
                        }
                        else
                        {
                            assert(false, "Invalid place: "~sp[0][0..$-1]);
                        }
                    }
                    else
                    {
                        assert(false, "No corresponding close paren");
                    }
                    break;
                default:
                    import std.format : format;
                    assert(false, format!"Invalid escape `%s%s`"(escape, rest[0]));
                }
            }
            else
            {
                resulted ~= str;
                break;
            }
        }
        while (true);
        return resulted;
    }

    @safe pure unittest
    {
        auto be = new BindingElement([Place("foo"): new Token("3")]);
        assert(commandWith("echo ~(foo)", be) == "echo 3", commandWith("echo ~(foo)", be));
    }

    @safe pure unittest
    {
        auto be = new BindingElement([Place("foo"): new Token("3")]);
        assert(commandWith("echo ~~(foo)", be) == "echo ~(foo)", commandWith("echo ~~(foo)", be));
    }

    @safe pure unittest
    {
        auto be = new BindingElement([Place("foo"): new Token("3")]);
        assert(commandWith("echo ~~~(foo)", be) == "echo ~3", commandWith("echo ~~~(foo)", be));
    }

    JSONValue startMsg(in BindingElement be, in Config con) const pure @safe
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "transition";
        ret["event"] = "start";
        ret["transition-type"] = "shell";
        ret["tag"] = con.tag;
        ret["name"] = name;
        ret["in"] = be.tokenElements.to!(string[string]);
        ret["out"] = arcExpFun.to!(string[string]);
        ret["command"] = commandWith(command, be);
        return ret;
    }
    
    JSONValue successMsg(in BindingElement ibe, in BindingElement obe, in Config con) const pure @safe
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "transition";
        ret["event"] = "end";
        ret["transition-type"] = "shell";
        ret["tag"] = con.tag;
        ret["name"] = name;
        ret["in"] = ibe.tokenElements.to!(string[string]);
        ret["out"] = obe.tokenElements.to!(string[string]);
        ret["command"] = commandWith(command, ibe);
        ret["success"] = true;
        return ret;
    }

    JSONValue failureMsg(in BindingElement be, in Config con, in string cause) const pure @safe
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "transition";
        ret["event"] = "end";
        ret["transition-type"] = "shell";
        ret["tag"] = con.tag;
        ret["name"] = name;
        ret["in"] = be.tokenElements.to!(string[string]);
        ret["out"] = arcExpFun.to!(string[string]);
        ret["command"] = commandWith(command, be);
        ret["success"] = false;
        ret["cause"] = cause;
        return ret;
    }

    string command;
}

/// ditto
alias ShellCommandTransition = immutable ShellCommandTransition_;

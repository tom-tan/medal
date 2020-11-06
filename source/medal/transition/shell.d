/**
 * Authors: Tomoya Tanjo
 * Copyright: © 2020 Tomoya Tanjo
 * License: Apache-2.0
 */
module medal.transition.shell;

import medal.logger : Logger, sharedLog;
//import medal.message;
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
alias ShellCommandTransition = immutable ShellCommandTransition_;

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
    protected override void fire(in BindingElement be, Tid networkTid, Logger logger = sharedLog)
    {
        import medal.message : SignalSent, TransitionFailed, TransitionSucceeded;
        import std.algorithm : canFind;
        import std.concurrency : receive, send, spawn;
        import std.file : remove;
        import std.process : Pid, spawnShell, tryWait;
        import std.stdio : File, stderr, stdin, stdout;
        import std.variant : Variant;

        logger.info(startMsg(be));
        scope(failure) logger.critical(failureMsg(be, "unknown error"));

        auto needStdout = arcExpFun.byValue.canFind!(p => p.pattern == SpecialPattern.Stdout);
        if (needStdout)
        {
            auto msg = "stdout is not yet supported";
            logger.info(failureMsg(be, msg));
            send(networkTid, TransitionFailed(be, msg));
            return;
        }
        // TODO: output file name should be random
        auto sout = needStdout ? File("stdout", "w") : stdout;
        scope(exit) if (needStdout) sout.name.remove;

        auto needStderr = arcExpFun.byValue.canFind!(p => p.pattern == SpecialPattern.Stderr);
        if (needStderr)
        {
            auto msg = "stderr is not yet supported";
            logger.info(failureMsg(be, msg));
            send(networkTid, TransitionFailed(be, msg));
            return;
        }
        // TODO: output file name should be random
        auto serr = needStderr ? File("stderr", "w") : stderr;
        scope(exit) if (needStderr) serr.name.remove;
        
        auto needReturn = arcExpFun.byValue.canFind!(p => p.pattern == SpecialPattern.Return);

        auto cmd = commandWith(be);
        auto pid = spawnShell(cmd, stdin, sout, serr);

		spawn((shared Pid pid) {
            import std.concurrency : ownerTid;
            import std.process : wait;
            // Note: if interrupted, it returns negative number
			auto code = wait(cast()pid);
			send(ownerTid, code);
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
                    logger.info(successMsg(be, ret));
                    send(networkTid,
                         TransitionSucceeded(ret));
                }
                else
                {
                    auto msg = "command returned with non-zero";
                    logger.info(failureMsg(be, msg));
                    send(networkTid,
                         TransitionFailed(be, msg));
                }
            },
            (in SignalSent sig) {
                import core.sys.posix.signal: SIGINT;
                import std.concurrency : receiveOnly;
                import std.format : format;
                import std.process : kill;

                kill(pid, SIGINT);
                receiveOnly!int;
                auto msg = format!"interrupted (%s)"(sig.no);
                logger.info(failureMsg(be, msg));
                send(networkTid,
                     TransitionFailed(be, msg));
            },
            (Variant v) {
                import core.sys.posix.signal: SIGINT;
                import std.concurrency : receiveOnly;
                import std.format : format;
                import std.process : kill;

                kill(pid, SIGINT);
                receiveOnly!int;

                auto msg = format!"unknown message (%s)"(v);
                logger.critical(failureMsg(be, msg));
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

    version(none)
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
                assert(ts.tokenElements == [Place("foo"): new Token("bar")]);
            },
            (Variant v) { assert(false, v.to!string); },
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
                assert(tf.tokenElements.empty);
            },
            (Variant v) { assert(false); },
        );
        assert(received);
    }
private:
    string commandWith(in BindingElement be) const pure @safe
    {
        import std.algorithm : fold;
        import std.array : byPair, replace;
        import std.conv : to;
        import std.format : format;
        return be.tokenElements.byPair.fold!((acc, p) {
            return acc.replace(format!"#{%s}"(p.key), p.value.to!string);
        })(command);
    }

    @safe pure unittest
    {
        auto t = new ShellCommandTransition("", "echo #{foo}", Guard.init,
                                            ArcExpressionFunction.init);
        auto be = new BindingElement([Place("foo"): new Token("3")]);
        assert(t.commandWith(be) == "echo 3", t.commandWith(be));
    }

    JSONValue startMsg(in BindingElement be) const pure @safe
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "transition";
        ret["event"] = "start";
        ret["transition-type"] = "shell";
        ret["name"] = name;
        ret["in"] = be.tokenElements.to!(string[string]);
        ret["out"] = arcExpFun.to!(string[string]);
        ret["command"] = command;
        return ret;
    }
    
    JSONValue successMsg(in BindingElement ibe, in BindingElement obe) const pure @safe
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "transition";
        ret["event"] = "end";
        ret["transition-type"] = "shell";
        ret["name"] = name;
        ret["in"] = ibe.tokenElements.to!(string[string]);
        ret["out"] = obe.tokenElements.to!(string[string]);
        ret["command"] = command;
        ret["success"] = true;
        return ret;
    }

    JSONValue failureMsg(in BindingElement be, in string cause) const pure @safe
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "transition";
        ret["event"] = "end";
        ret["transition-type"] = "shell";
        ret["name"] = name;
        ret["in"] = be.tokenElements.to!(string[string]);
        ret["out"] = arcExpFun.to!(string[string]);
        ret["command"] = command;
        ret["success"] = false;
        ret["cause"] = cause;
        return ret;
    }

    string command;
}

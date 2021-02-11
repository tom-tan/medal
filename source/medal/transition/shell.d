/**
 * Authors: Tomoya Tanjo
 * Copyright: © 2020 Tomoya Tanjo
 * License: Apache-2.0
 */
module medal.transition.shell;

import medal.config : Config;
import medal.logger : Logger, sharedLog;
import medal.transition.core;

import std.algorithm : all;
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
    protected override void fire(in BindingElement be, Tid networkTid,
                                 Config con = Config.init, Logger logger = sharedLog)
    {
        import medal.message : SignalSent, TransitionInterrupted, TransitionFailed, TransitionSucceeded;
        import medal.utils.process : kill, Pid, spawnProcess, tryWait, ProcessConfig = Config, wait;

        import std.algorithm : canFind, either, filter;
        import std.concurrency : receive, send, spawn;
        import std.file : getcwd, remove;
        import std.stdio : File, stdin;
        import std.variant : Variant;

        logger.info(startMsg(be, con));
        scope(failure) logger.critical(failureMsg(be, command, con, "Unknown error"));

        auto tmpdir = either(con.tmpdir, getcwd);
        auto stdoutPlaces = arcExpFun.byKey.filter!(p => arcExpFun[p].type == PatternType.Stdout);
        File sout;
        if (!stdoutPlaces.empty)
        {
            import std.format : format;
            import std.path : buildPath;
            import std.uuid : randomUUID;

            auto fname = format!"%s-%s"(stdoutPlaces.front, randomUUID);
            sout = File(buildPath(tmpdir, fname), "w");
        }
        else
        {
            import std.stdio : stdout;
            sout = stdout;
        }

        auto stderrPlaces = arcExpFun.byKey.filter!(p => arcExpFun[p].type == PatternType.Stderr);
        File serr;
        if (!stderrPlaces.empty)
        {
            import std.format : format;
            import std.path : buildPath;
            import std.uuid : randomUUID;
            auto fname = format!"%s-%s"(stderrPlaces.front, randomUUID);
            serr = File(buildPath(tmpdir, fname), "w");
        }
        else
        {
            import std.stdio : stderr;
            serr = stderr;
        }

        auto filePlaces = arcExpFun.byKey.filter!(p => arcExpFun[p].type == PatternType.File);
        string[Place] files;
        if (!filePlaces.empty)
        {
            import std.algorithm : map;
            import std.array : assocArray;
            import std.format : format;
            import std.path : buildPath;
            import std.typecons : tuple;
            import std.uuid : randomUUID;
            files = filePlaces.map!(f => tuple(f, buildPath(tmpdir, format!"%s-%s"(f, randomUUID))))
                              .assocArray;
        }

        auto needReturn = arcExpFun.byValue.canFind!(p => p.type == PatternType.Return);

        auto cmd = commandWith(command, be, files);
        logger.trace(constructMsg(be, cmd, con));
        auto pid = spawnProcess(["bash", "-eo", "pipefail", "-c", cmd], stdin, sout, serr, ["MEDAL_TMPDIR": con.tmpdir],
                                ProcessConfig.none, con.workdir);

		spawn((shared Pid pid) {
            import std.concurrency : ownerTid;
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
            if (!stdoutPlaces.empty)
            {
                result.stdout = sout.name;
            }
            if (!stderrPlaces.empty)
            {
                result.stderr = serr.name;
            }
            result.files = files;
            return arcExpFun.apply(be, result);
        }

        receive(
            (int code) {
                auto ret = result2BE(code);
                if (needReturn || code == 0)
                {
                    logger.info(successMsg(be, ret, cmd, con));
                    send(networkTid,
                         TransitionSucceeded(ret));
                }
                else
                {
                    import std.format : format;

                    auto msg = format!"command returned with non-zero (%s)"(code);
                    logger.info(failureMsg(be, cmd, con, msg));
                    send(networkTid,
                         TransitionFailed(be, msg));
                }
            },
            (in SignalSent sig) {
                import std.concurrency : receiveOnly;
                import std.format : format;

                auto msg = format!"interrupted (%s)"(sig.no);
                logger.info(failureMsg(be, cmd, con, msg));

                logger.tracef("kill %s", pid.processID);
                kill(pid);
                logger.tracef("killed %s", pid.processID);
                auto ret = receiveOnly!int;
                logger.tracef("receive return code %s for %s", ret, pid.processID);
                send(networkTid, TransitionInterrupted(be));
            },
            (Variant v) {
                import std.concurrency : receiveOnly;
                import std.format : format;

                kill(pid);
                receiveOnly!int;

                auto msg = format!"unknown message (%s)"(v);
                logger.critical(failureMsg(be, cmd, con, msg));
                send(networkTid, TransitionFailed(be, msg));
            }
        );
        assert(tryWait(pid).terminated);
    }

    version(Posix)
    unittest
    {
        import medal.message : TransitionSucceeded;
        import std.concurrency : LinkTerminated, receive, receiveOnly, thisTid;
        import std.conv : to;
        import std.variant : Variant;

        auto sct = new ShellCommandTransition("", "true", Guard.init,
                                              ArcExpressionFunction.init);
        auto tid = spawnFire(sct, new BindingElement, thisTid);
        scope(exit)
        {
            assert(tid.to!string == receiveOnly!LinkTerminated.tid.to!string);
        }
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
        import std.concurrency : LinkTerminated, receive, receiveOnly, thisTid;
        import std.conv : to;
        import std.variant : Variant;

        auto sct = new ShellCommandTransition("", "false", Guard.init,
                                              ArcExpressionFunction.init);
        auto tid = spawnFire(sct, new BindingElement, thisTid);
        scope(exit)
        {
            assert(tid.to!string == receiveOnly!LinkTerminated.tid.to!string);
        }
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
        import std.concurrency : LinkTerminated, receive, receiveOnly, thisTid;
        import std.conv : to;
        import std.variant : Variant;

        immutable aef = [
            "foo": SpecialPattern.Return,
        ].to!ArcExpressionFunction_;
        auto sct = new ShellCommandTransition("", "true", Guard.init, aef);
        auto tid = spawnFire(sct, new BindingElement, thisTid);
        scope(exit)
        {
            assert(tid.to!string == receiveOnly!LinkTerminated.tid.to!string);
        }
        receive(
            (TransitionSucceeded ts) {
                assert(ts.tokenElements == [
                    "foo": "0"
                ].to!(Token[Place]));
            },
            (Variant v) { assert(false, "Caught: "~v.to!string); },
        );
    }

    unittest
    {
        import medal.message : TransitionSucceeded;
        import std.concurrency : LinkTerminated, receive, receiveOnly, thisTid;
        import std.conv : to;
        import std.variant : Variant;

        immutable aef = [
            "foo": SpecialPattern.Stdout,
        ].to!ArcExpressionFunction_;
        auto sct = new ShellCommandTransition("", "echo bar", Guard.init, aef);
        auto tid = spawnFire(sct, new BindingElement, thisTid);
        scope(exit)
        {
            assert(tid.to!string == receiveOnly!LinkTerminated.tid.to!string);
        }
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
        import medal.message : SignalSent, TransitionInterrupted;
        import std.concurrency : LinkTerminated, receiveOnly, receiveTimeout, send, thisTid;
        import std.conv : to;
        import std.datetime : seconds;
        import std.variant : Variant;

        immutable aef = [
            "foo": SpecialPattern.Return,
        ].to!ArcExpressionFunction_;
        auto sct = new ShellCommandTransition("", "sleep infinity", Guard.init, aef);
        auto tid = spawnFire(sct, new BindingElement, thisTid);
        scope(exit)
        {
            assert(tid.to!string == receiveOnly!LinkTerminated.tid.to!string);
        }
        send(tid, SignalSent(SIGINT));
        auto received = receiveTimeout(30.seconds,
            (TransitionInterrupted ti) {
                assert(ti.tokenElements.empty);
            },
            (Variant v) { assert(false); },
        );
        assert(received);
    }
private:
    static string commandWith(in string cmd, in BindingElement be, in string[Place] outFiles) pure @safe
    in(outFiles.byKey.all!(p => p !in be.tokenElements))
    do
    {
        import std.algorithm : findSplitAfter;
        import std.array : assocArray, byPair;
        import std.conv : to;
        import std.range : chain;

        enum escape = '~';

        auto aa = chain(be.tokenElements.to!(string[string]).byPair,
                        outFiles.to!(string[string]).byPair).assocArray;
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
        import std.conv : to;
        auto be = new BindingElement(["foo": "3"].to!(Token[Place]));
        auto cmd = commandWith("echo ~(foo)", be, (string[Place]).init);
        assert(cmd == "echo 3", cmd);
    }

    @safe pure unittest
    {
        import std.conv : to;
        auto be = new BindingElement(["foo": "3"].to!(Token[Place]));
        auto cmd = commandWith("echo ~~(foo)", be, (string[Place]).init);
        assert(cmd == "echo ~(foo)", cmd);
    }

    @safe pure unittest
    {
        import std.conv : to;
        auto be = new BindingElement(["foo": "3"].to!(Token[Place]));
        auto cmd = commandWith("echo ~~~(foo)", be, (string[Place]).init);
        assert(cmd == "echo ~3", cmd);
    }

    @safe pure unittest
    {
        import std.conv : to;
        auto be = new BindingElement(["foo": "3"].to!(Token[Place]));
        auto outFiles = [
            Place("bar"): "output.txt"
        ];
        auto cmd = commandWith("echo ~(foo) > ~(bar)", be, outFiles);
        assert(cmd == "echo 3 > output.txt", cmd);
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
        ret["command"] = command;
        ret["workdir"] = con.workdir;
        ret["tmpdir"] = con.tmpdir;
        return ret;
    }

    JSONValue constructMsg(in BindingElement be, in string cmd, in Config con) const pure @safe
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "transition";
        ret["event"] = "construct-command";
        ret["transition-type"] = "shell";
        ret["tag"] = con.tag;
        ret["name"] = name;
        ret["in"] = be.tokenElements.to!(string[string]);
        ret["out"] = arcExpFun.to!(string[string]);
        ret["command"] = command;
        ret["constructed-command"] = cmd;
        ret["workdir"] = con.workdir;
        ret["tmpdir"] = con.tmpdir;
        return ret;
    }

    JSONValue successMsg(in BindingElement ibe, in BindingElement obe, in string cmd, in Config con) const pure @safe
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
        ret["command"] = cmd;
        ret["success"] = true;
        ret["workdir"] = con.workdir;
        ret["tmpdir"] = con.tmpdir;
        return ret;
    }

    JSONValue failureMsg(in BindingElement be, in string cmd, in Config con, in string cause) const pure @safe
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
        ret["command"] = cmd;
        ret["success"] = false;
        ret["cause"] = cause;
        ret["workdir"] = con.workdir;
        ret["tmpdir"] = con.tmpdir;
        return ret;
    }

    string command;
}

/// ditto
alias ShellCommandTransition = immutable ShellCommandTransition_;

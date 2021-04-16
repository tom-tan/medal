/**
 * Authors: Tomoya Tanjo
 * Copyright: © 2020 Tomoya Tanjo
 * License: Apache-2.0
 */
module medal.transition.shell;

import medal.config : Config;
import medal.logger : Logger, LogType, NullLogger, nullLoggers, userLog;
import medal.transition.core;

import std.algorithm : all;
import std.concurrency : Tid;
import std.json : JSONValue;
import std.range : empty;

///
immutable class ShellCommandTransition_: Transition
{
    ///
    this(string name, string cmd, in Guard guard, in ArcExpressionFunction aef,
         string pre = "", string success = "", string failure = "") @nogc nothrow pure @safe
    in(!cmd.empty)
    do
    {
        super(name, guard, aef, pre, success, failure);
        command = cmd;
    }

    ///
    protected override void fire(in BindingElement be, Tid networkTid,
                                 Config con = Config.init, Logger[LogType] loggers = nullLoggers)
    {
        import medal.message : SignalSent, TransitionInterrupted, TransitionFailed, TransitionSucceeded;
        import medal.utils.process : kill, Pid, spawnProcess, tryWait, ProcessConfig = Config, wait;

        import std.algorithm : canFind, either, filter;
        import std.concurrency : receive, send, spawn;
        import std.conv : to;
        import std.file : getcwd, remove;
        import std.format : format;
        import std.path : buildPath;
        import std.stdio : File, stdin;
        import std.uuid : randomUUID;
        import std.variant : Variant;

        auto sysLogger = loggers[LogType.System];
        auto appLogger = loggers[LogType.App];

        auto tmpdir = either(con.tmpdir, getcwd);

        JSONValue internalBE;
        internalBE["in"] = be.tokenElements.to!(string[string]);
        internalBE["workdir"] = con.workdir;
        internalBE["tmpdir"] = tmpdir;
        internalBE["tag"] = con.tag;

        sysLogger.info(startMsg(be, con));
        appLogger.userLog(preLogEntry, internalBE, con);
        scope(failure) sysLogger.critical(failureMsg(be, command, string[string].init, con, "Unknown error"));

        auto filePlaces = arcExpFun.byKey.filter!(p => arcExpFun[p] == SpecialPattern.File);
        if (!filePlaces.empty)
        {
            import std.algorithm : map;
            import std.array : assocArray;
            import std.typecons : tuple;
            auto newfiles = filePlaces.map!(f => tuple(f.name, buildPath(tmpdir, format!"%s-%s"(f, randomUUID))))
                                      .assocArray;
            internalBE["out"] = newfiles;
            internalBE["tr"] = [ "newfile": newfiles ];
        }
        else
        {
            internalBE["tr"] = JSONValue((string[string]).init);
        }

        auto cmd = commandWith(command, internalBE);
        string[string] newEnv = con.evaledEnv;

        auto stdoutName = buildPath(tmpdir, format!"tr-%s-stdout-%s"(name, randomUUID));
        auto sout = File(stdoutName, "w");
        auto stderrName = buildPath(tmpdir, format!"tr-%s-stderr-%s"(name, randomUUID));
        auto serr = File(stderrName, "w");

        internalBE["tr"] = [
            "stdout": stdoutName,
            "stderr": stderrName,
        ];

        sysLogger.trace(constructMsg(be, cmd, newEnv, con));
        auto pid = spawnProcess(["bash", "-eo", "pipefail", "-c", cmd], stdin, sout, serr,
                                newEnv, ProcessConfig.newEnv, con.workdir);

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

        receive(
            (int code) {
                internalBE["tr"]["return"] = code;
                internalBE["interrupted"] = false;
                auto needReturn = arcExpFun.byValue.canFind(SpecialPattern.Return);

                if (needReturn || code == 0)
                {
                    auto ret = arcExpFun.apply(internalBE);
                    internalBE["out"] = ret.tokenElements.to!(string[string]);

                    sysLogger.info(successMsg(be, ret, cmd, newEnv, con));
                    appLogger.userLog(successLogEntry, internalBE, con);
                    send(networkTid,
                         TransitionSucceeded(ret));
                }
                else
                {
                    import std.format : format;

                    auto msg = format!"command returned with non-zero (%s)"(code);
                    sysLogger.error(failureMsg(be, cmd, newEnv, con, msg));
                    appLogger.userLog(failureLogEntry, internalBE, con);
                    send(networkTid,
                         TransitionFailed(be, msg));
                }
            },
            (in SignalSent sig) {
                import std.concurrency : receiveOnly;
                import std.format : format;
                import std.math : abs;

                auto msg = format!"interrupted (%s)"(sig.no);
                sysLogger.error(failureMsg(be, cmd, newEnv, con, msg));

                auto id = pid.processID;
                sysLogger.tracef("kill %s", id);
                kill(pid);
                sysLogger.tracef("killed %s", id);
                auto ret = receiveOnly!int;
                sysLogger.tracef("receive return code %s for %s", ret, id);
                internalBE["tr"]["return"] = ret.abs;
                internalBE["interrupted"] = ret < 0;
                // TODO: interrupted or not

                appLogger.userLog(failureLogEntry, internalBE, con);
                send(networkTid, TransitionInterrupted(be));
            },
            (Variant v) {
                import std.concurrency : receiveOnly;
                import std.format : format;
                import std.math : abs;

                kill(pid);
                auto ret = receiveOnly!int;
                internalBE["tr"]["return"] = ret.abs;
                internalBE["interrupted"] = false;

                auto msg = format!"unknown message (%s)"(v);
                sysLogger.critical(failureMsg(be, cmd, newEnv, con, msg));
                appLogger.userLog(failureLogEntry, internalBE, con);
                send(networkTid, TransitionFailed(be, msg));
            }
        );
        assert(tryWait(pid).terminated);
    }

    version(Posix)
    unittest
    {
        import medal.logger : JSONLogger;
        import medal.message : TransitionSucceeded;
        import std.concurrency : LinkTerminated, receive, receiveOnly, thisTid;
        import std.conv : to;
        import std.file : mkdirRecurse, rmdirRecurse;
        import std.path : buildPath;
        import std.uuid : randomUUID;
        import std.variant : Variant;

        auto dir = randomUUID.to!string;
        mkdirRecurse(dir);
        scope(success) rmdirRecurse(dir);

        Config con = { tmpdir: dir };

        auto loggers = nullLoggers;
        loggers[LogType.System] = new JSONLogger(buildPath(dir, "medal.jsonl"));

        auto sct = new ShellCommandTransition("", "true", Guard.init,
                                              ArcExpressionFunction.init);
        auto tid = spawnFire(sct, new BindingElement, thisTid,
                             con, loggers);
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
        import medal.logger : JSONLogger;
        import medal.message : TransitionFailed;
        import std.concurrency : LinkTerminated, receiveOnly, thisTid;
        import std.conv : to;
        import std.file : mkdirRecurse, rmdirRecurse;
        import std.path : buildPath;
        import std.uuid : randomUUID;
        import std.variant : Variant;

        auto dir = randomUUID.to!string;
        mkdirRecurse(dir);
        scope(success) rmdirRecurse(dir);

        Config con = { tmpdir: dir };

        auto loggers = nullLoggers;
        loggers[LogType.System] = new JSONLogger(buildPath(dir, "medal.jsonl"));

        auto sct = new ShellCommandTransition("", "false", Guard.init,
                                              ArcExpressionFunction.init);
        auto tid = spawnFire(sct, new BindingElement, thisTid,
                             con, loggers);
        scope(exit)
        {
            assert(tid.to!string == receiveOnly!LinkTerminated.tid.to!string);
        }
        auto tf = receiveOnly!TransitionFailed;
        assert(tf.tokenElements.empty);
    }

    ///
    version(Posix)
    unittest
    {
        import medal.logger : JSONLogger;
        import medal.message : TransitionSucceeded;
        import std.concurrency : LinkTerminated, receiveOnly, thisTid;
        import std.conv : asOriginalType, to;
        import std.file : mkdirRecurse, rmdirRecurse;
        import std.path : buildPath;
        import std.uuid : randomUUID;
        import std.variant : Variant;

        auto dir = randomUUID.to!string;
        mkdirRecurse(dir);
        scope(success) rmdirRecurse(dir);

        Config con = { tmpdir: dir };

        auto loggers = nullLoggers;
        loggers[LogType.System] = new JSONLogger(buildPath(dir, "medal.jsonl"));

        immutable aef = [
            "foo": SpecialPattern.Return.asOriginalType,
        ].to!ArcExpressionFunction_;
        auto sct = new ShellCommandTransition("", "true", Guard.init, aef);
        auto tid = spawnFire(sct, new BindingElement, thisTid,
                             con, loggers);
        scope(exit)
        {
            assert(tid.to!string == receiveOnly!LinkTerminated.tid.to!string);
        }
        auto ts = receiveOnly!TransitionSucceeded;
        assert(ts.tokenElements == [
            "foo": "0"
        ].to!(Token[Place]));
    }

    unittest
    {
        import medal.logger : JSONLogger;
        import medal.message : TransitionSucceeded;
        import std.concurrency : LinkTerminated, receiveOnly, thisTid;
        import std.conv : asOriginalType, to;
        import std.file : exists, mkdirRecurse, readText, remove, rmdirRecurse;
        import std.path : buildPath;
        import std.uuid : randomUUID;
        import std.variant : Variant;

        auto dir = randomUUID.to!string;
        mkdirRecurse(dir);
        scope(success) rmdirRecurse(dir);

        Config con = { tmpdir: dir };

        auto loggers = nullLoggers;
        loggers[LogType.System] = new JSONLogger(buildPath(dir, "medal.jsonl"));

        immutable aef = [
            "foo": SpecialPattern.Stdout.asOriginalType,
        ].to!ArcExpressionFunction_;
        auto sct = new ShellCommandTransition("", "echo bar", Guard.init, aef);
        auto tid = spawnFire(sct, new BindingElement, thisTid,
                             con, loggers);
        scope(exit)
        {
            assert(tid.to!string == receiveOnly!LinkTerminated.tid.to!string);
        }
        auto ts = receiveOnly!TransitionSucceeded;

        auto token = Place("foo") in ts.tokenElements.tokenElements;
        assert(token);

        auto name = token.value;
        assert(name.exists);
        scope(exit) name.remove;
        assert(name.readText == "bar\n");
    }

    version(Posix)
    unittest
    {
        import core.sys.posix.signal: SIGINT;
        import medal.logger : JSONLogger;
        import medal.message : SignalSent, TransitionInterrupted;
        import std.concurrency : LinkTerminated, receiveOnly, receiveTimeout, send, thisTid;
        import std.conv : asOriginalType, to;
        import std.datetime : seconds;
        import std.file : mkdirRecurse, rmdirRecurse;
        import std.path : buildPath;
        import std.uuid : randomUUID;
        import std.variant : Variant;

        auto dir = randomUUID.to!string;
        mkdirRecurse(dir);
        scope(success) rmdirRecurse(dir);

        Config con = { tmpdir: dir };

        auto loggers = nullLoggers;
        loggers[LogType.System] = new JSONLogger(buildPath(dir, "medal.jsonl"));

        immutable aef = [
            "foo": SpecialPattern.Return.asOriginalType,
        ].to!ArcExpressionFunction_;
        auto sct = new ShellCommandTransition("", "sleep infinity", Guard.init, aef);
        auto tid = spawnFire(sct, new BindingElement, thisTid,
                             con, loggers);
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
    static auto commandWith(in string cmd, in JSONValue be)
    {
        return cmd.substitute(be);
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

    JSONValue constructMsg(in BindingElement be, in string cmd, in string[string] env, in Config con) const pure @safe
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
        ret["env"] = env;
        return ret;
    }

    JSONValue successMsg(in BindingElement ibe, in BindingElement obe, in string cmd, in string[string] env,
                         in Config con) const pure @safe
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
        ret["env"] = env;
        return ret;
    }

    JSONValue failureMsg(in BindingElement be, in string cmd, in string[string] env,
                         in Config con, in string cause) const pure @safe
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
        ret["env"] = env;
        return ret;
    }

    string command;
}

/// ditto
alias ShellCommandTransition = immutable ShellCommandTransition_;

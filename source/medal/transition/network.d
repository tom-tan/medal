/**
 * Authors: Tomoya Tanjo
 * Copyright: © 2020 Tomoya Tanjo
 * License: Apache-2.0
 */
module medal.transition.network;

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
immutable class InvocationTransition_: Transition
{
    ///
    this(in string name, in Guard g1, in Guard g2, in Transition[] trs,
         immutable Config con = Config.init) @nogc nothrow pure @safe
    in(!trs.empty)
    do 
    {
        super(name, g1, ArcExpressionFunction.init);
        transitions = trs;
        stopGuard = g2;
        config = con;
    }

protected:
    ///
    override void fire(in BindingElement initBe, Tid networkTid, Config con = Config.init, Logger logger = sharedLog)
    {
        import medal.engine : Engine;
        import medal.message : TransitionFailed, TransitionSucceeded;

        import std.algorithm : either;
        import std.concurrency : send;

        Config engineConfig = {
            tag: either(con.tag, config.tag),
            environment: config.environment,
            workdir: con.workdir,
            tmpdir: either(con.tmpdir, config.tmpdir),
        };

        logger.info(startMsg(initBe, con));
        scope(failure) logger.critical(failureMsg(initBe, con, "internal transition failed"));
        auto engine = Engine(transitions, stopGuard);
        auto retBe = engine.run(initBe, engineConfig, logger);
        if (retBe)
        {
            logger.info(successMsg(initBe, retBe, con));
            send(networkTid, TransitionSucceeded(retBe));
        }
        else
        {
            logger.info(failureMsg(initBe, con, "internal transition failed"));
            send(networkTid, TransitionFailed(initBe));
        }
    }

private:
    JSONValue startMsg(in BindingElement be, in Config con) const pure @safe
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "transition";
        ret["event"] = "start";
        ret["transition-type"] = "network";
        ret["tag"] = con.tag;
        ret["name"] = name;
        ret["in"] = be.tokenElements.to!(string[string]);
        ret["out"] = stopGuard.to!(string[string]);
        return ret;
    }
    
    JSONValue successMsg(in BindingElement ibe, in BindingElement obe, in Config con) const pure @safe
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "transition";
        ret["event"] = "end";
        ret["transition-type"] = "network";
        ret["tag"] = con.tag;
        ret["name"] = name;
        ret["in"] = ibe.tokenElements.to!(string[string]);
        ret["out"] = obe.tokenElements.to!(string[string]);
        ret["success"] = true;
        return ret;
    }

    JSONValue failureMsg(in BindingElement be, in Config con, in string cause = "") const pure @safe
    {
        import std.conv : to;

        JSONValue ret;
        ret["evente"] = "end";
        ret["transition-type"] = "network";
        ret["tag"] = con.tag;
        ret["name"] = name;
        ret["in"] = be.tokenElements.to!(string[string]);
        ret["out"] = stopGuard.to!(string[string]);
        ret["success"] = false;
        ret["cause"] = cause;
        return ret;
    }

    Transition[] transitions;
    Guard stopGuard;
    Config config;
}

/// ditto
alias InvocationTransition = immutable InvocationTransition_;

unittest
{
    import medal.message : TransitionSucceeded;
    import medal.transition.shell : ShellCommandTransition;

    import std.concurrency : receive, thisTid;
    import std.variant : Variant;

    immutable aef = [
        Place("bar"): OutputPattern(SpecialPattern.Return),
    ];
    immutable g = [
        Place("foo"): InputPattern(SpecialPattern.Any),
    ];
    auto sct = new ShellCommandTransition("", "true ~(foo)", g, aef);
    Transition[] trs = [sct];
    immutable portGuard = [
        Place("bar"): InputPattern(SpecialPattern.Any),
    ];
    auto net = new InvocationTransition("", g, portGuard, trs);

    spawnFire(net, new BindingElement([Place("foo"): new Token("yahoo")]), thisTid);
    receive(
        (TransitionSucceeded ts) {
            assert(ts.tokenElements == [Place("bar"): new Token("0")]);
        },
        (Variant _) { assert(false); },
    );
}

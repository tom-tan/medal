/**
 * Authors: Tomoya Tanjo
 * Copyright: © 2020 Tomoya Tanjo
 * License: Apache-2.0
 */
module medal.transition.network;

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
alias InvocationTransition = immutable InvocationTransition_;
///
immutable class InvocationTransition_: Transition
{
    ///
    this(in Guard g1, in Guard g2, in Transition[] trs) pure
    in(!trs.empty)
    do 
    {
        super(g1, ArcExpressionFunction.init);
        transitions = trs;
        stopGuard = g2;
    }

    ///
    override void fire(in BindingElement initBe, Tid networkTid, Logger logger = sharedLog)
    {
        import medal.engine : Engine;
        import medal.message : TransitionFailed, TransitionSucceeded;

        import std.concurrency : send;

        logger.info(startMsg(initBe));
        scope(failure) logger.critical(failureMsg(initBe, "internal transition failed"));
        auto engine = Engine(transitions, stopGuard);
        auto retBe = engine.run(initBe);
        if (retBe)
        {
            logger.info(successMsg(initBe, retBe));
            send(networkTid, TransitionSucceeded(retBe));
        }
        else
        {
            logger.info(failureMsg(initBe, "internal transition failed"));
            send(networkTid, TransitionFailed(initBe));
        }
    }

private:
    JSONValue startMsg(in BindingElement be)
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "transition";
        ret["event"] = "start";
        ret["transition-type"] = "network";
        ret["in"] = be.tokenElements.to!(string[string]);
        ret["out"] = stopGuard.to!(string[string]);
        return ret;
    }
    
    JSONValue successMsg(in BindingElement ibe, in BindingElement obe)
    {
        import std.conv : to;

        JSONValue ret;
        ret["sender"] = "transition";
        ret["event"] = "end";
        ret["transition-type"] = "network";
        ret["in"] = ibe.tokenElements.to!(string[string]);
        ret["out"] = obe.tokenElements.to!(string[string]);
        ret["success"] = true;
        return ret;
    }

    JSONValue failureMsg(in BindingElement be, in string cause = "")
    {
        import std.conv : to;

        JSONValue ret;
        ret["evente"] = "end";
        ret["transition-type"] = "network";
        ret["in"] = be.tokenElements.to!(string[string]);
        ret["out"] = stopGuard.to!(string[string]);
        ret["success"] = false;
        ret["cause"] = cause;
        return ret;
    }

    Transition[] transitions;
    Guard stopGuard;
}

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
    auto sct = new ShellCommandTransition("true #{foo}", g, aef);
    Transition[] trs = [sct];
    immutable portGuard = [
        Place("bar"): InputPattern(SpecialPattern.Any),
    ];
    auto net = new InvocationTransition(g, portGuard, trs);

    spawnFire(net, new BindingElement([Place("foo"): new Token("yahoo")]), thisTid);
    receive(
        (TransitionSucceeded ts) {
            assert(ts.tokenElements == [Place("bar"): new Token("0")]);
        },
        (Variant _) { assert(false); },
    );
}

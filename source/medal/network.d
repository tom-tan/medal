/**
 * Authors: Tomoya Tanjo
 * Copyright: © 2020 Tomoya Tanjo
 * License: Apache-2.0
 */
module medal.network;

import medal.transition;
import medal.engine;

import std;
import std.experimental.logger;

version(unittest)
shared static this()
{
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
    spawn({
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
        net.fire(new BindingElement([Place("foo"): new Token("yahoo")]), ownerTid);
    });
    receive(
        (TransitionSucceeded ts) {
            assert(ts.tokenElements == [Place("bar"): new Token("0")]);
        },
        (Variant _) { assert(false); },
    );
}

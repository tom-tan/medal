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
        logger.info("start.");
        scope(failure) logger.critical("unintended failure");
        auto engine = Engine(transitions, stopGuard);
        auto retBe = engine.run(initBe);
        if (retBe)
        {
            logger.info("success.");
            send(networkTid, TransitionSucceeded(retBe));
        }
        else
        {
            logger.info("failure.");
            send(networkTid, TransitionFailed(initBe));
        }
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

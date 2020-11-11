/**
 * Authors: Tomoya Tanjo
 * Copyright: © 2020 Tomoya Tanjo
 * License: Apache-2.0
 */
module medal.logger;

import std.datetime.timezone : TimeZone;
import std.stdio : File;

public import std.experimental.logger : LogLevel, Logger, sharedLog;

///
@safe class JSONLogger: Logger
{
    ///
    this(const string fn, const LogLevel lv = LogLevel.all)
    {
        import std.datetime.systime : Clock;
        import std.datetime.timezone : SimpleTimeZone;

        super(lv);
        this.filename = fn;
        this.file_.open(this.filename, "a");
        auto now = Clock.currTime;
        auto offset = now.utcOffset;
        tz = new immutable SimpleTimeZone(offset);
    }

    ///
    this(File file, const LogLevel lv = LogLevel.all)
    {
        import std.datetime.systime : Clock;
        import std.datetime.timezone : SimpleTimeZone;

        super(lv);
        this.file_ = file;
        auto now = Clock.currTime;
        auto offset = now.utcOffset;
        tz = new immutable SimpleTimeZone(offset);
    }

    ///
    @property File file() nothrow
    {
        return this.file_;
    }

    override void writeLogMsg(ref LogEntry payload)
    {
        import std.conv : to;
        import std.exception : ifThrown;
        import std.json : JSONException, JSONValue, parseJSON;

        JSONValue log;
        log["timestamp"] = payload.timestamp.toOtherTZ(tz).toISOExtString;
        log["thread-id"] = () @trusted { return payload.threadId.to!string[4..$-1]; }();
        log["log-level"] = payload.logLevel.to!string;
        auto json = parseJSON(payload.msg).ifThrown!JSONException(JSONValue(["message": payload.msg]));
        log["payload"] = json;
        file.writeln(log);
        file.flush;
    }

    protected File file_;
    protected string filename;
    protected immutable TimeZone tz;
}

/**
 * Authors: Tomoya Tanjo
 * Copyright: © 2020 Tomoya Tanjo
 * License: Apache-2.0
 */
module medal.logger;

import std;
import std.experimental.logger;

///
class JSONLogger: Logger
{
    ///
    this(const string fn, const LogLevel lv = LogLevel.all)
    {
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
        super(lv);
        this.file_ = file;
        auto now = Clock.currTime;
        auto offset = now.utcOffset;
        tz = new immutable SimpleTimeZone(offset);
    }

    ///
    @property File file()
    {
        return this.file_;
    }

    override void writeLogMsg(ref LogEntry payload) @trusted
    {
        JSONValue log;
        log["timestamp"] = payload.timestamp.toOtherTZ(tz).toISOExtString;
        log["thread-id"] = payload.threadId.to!string;
        log["log-level"] = payload.logLevel.to!string;
        auto json = parseJSON(payload.msg).ifThrown!JSONException(JSONValue(["message": payload.msg]));
        log["payload"] = json;
        file.writeln(log);
    }

    protected File file_;
    protected string filename;
    protected immutable TimeZone tz;
}

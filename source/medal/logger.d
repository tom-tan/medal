module medal.logger;

import std;
import std.experimental.logger;

class JSONLogger: Logger
{
    this(const string fn, const LogLevel lv = LogLevel.all)
    {
        super(lv);
        this.filename = fn;
        this.file_.open(this.filename, "a");
    }

    this(File file, const LogLevel lv = LogLevel.all)
    {
        super(lv);
        this.file_ = file;
    }

    @property File file()
    {
        return this.file_;
    }

    override void writeLogMsg(ref LogEntry payload) @trusted
    {
        JSONValue log;
        payload.timestamp.timezone = LocalTime();
        log["date"] = payload.timestamp.toISOExtString;
        log["tid"] = payload.threadId.to!string;
        auto json = parseJSON(payload.msg).ifThrown!JSONException(JSONValue(["message": payload.msg]));
        log["payload"] = json;
        file.writeln(log.toString);
    }

    protected File file_;
    protected string filename;
}

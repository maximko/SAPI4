import vibe.vibe;
import std.algorithm;
import std.conv;
import std.string;
import std.array;
import std.process;
import core.stdc.stdlib;
import std.datetime;
import std.format : format;
import std.parallelism;
import std.file;

enum string NIKOLAI_VOICE = "Digalo Russian Nicolai";

bool linuxFfmpegAvailable()
{
	return exists(`Z:\usr\bin\ffmpeg`);
}

string unixPathForWorkingFile(string file)
{
	auto cwd = getcwd().replace('\\', '/');
	if (cwd.length < 3 || cwd[1] != ':' || (cwd[0] != 'Z' && cwd[0] != 'z'))
		return "";

	return cwd[2 .. $] ~ "/" ~ file;
}

string tempoFilter(double tempo)
{
	// FFmpeg's atempo filter accepts 0.5 and above. Chain two filters for
	// Nikolai's lowest rates, where max-rate synthesis needs more stretching.
	if (tempo < 0.5)
		return "atempo=0.5,atempo=" ~ format("%.8f", tempo / 0.5);
	return "atempo=" ~ format("%.8f", tempo);
}

bool restoreTempo(string file, long requestedSpeed, uint synthesisSpeed)
{
	auto input = unixPathForWorkingFile(file);
	auto outputFile = file ~ ".tempo.wav";
	auto output = unixPathForWorkingFile(outputFile);
	if (input == "" || output == "")
		return false;

	if (exists(outputFile))
		remove(outputFile);

	// Wine's start.exe /unix bridge lets the Windows web server use the host's
	// FFmpeg. It returns before FFmpeg, so wait until the output has stopped
	// growing before replacing the original fast-speech WAV.
	auto launch = execute([
		"start.exe", "/unix", "/usr/bin/ffmpeg", "-nostdin", "-y",
		"-loglevel", "error", "-i", input, "-filter:a",
		tempoFilter(cast(double)requestedSpeed / synthesisSpeed),
		"-f", "wav", output
	]);
	if (launch.status != 0)
		return false;

	ulong previousSize;
	uint stableSamples;
	foreach (_; 0 .. 100) {
		if (exists(outputFile)) {
			auto currentSize = getSize(outputFile);
			if (currentSize > 44 && currentSize == previousSize)
				stableSamples++;
			else
				stableSamples = 0;
			previousSize = currentSize;

			if (stableSamples >= 3) {
				remove(file);
				rename(outputFile, file);
				return true;
			}
		}
		sleep(dur!"msecs"(100));
	}

	if (exists(outputFile))
		remove(outputFile);
	return false;
}

struct SAM {
	string voice;
	ushort defPitch, minPitch, maxPitch;
	uint defSpeed, minSpeed, maxSpeed;

	this(string voice)
	{
		auto proc = execute(["sapi4limits.exe", voice]);
		if (proc.status != 0) {
			logError("sapi4limits fail on %s", voice);
			exit(1);
		}
		auto spl = proc.output.replace("err:xrandr:xrandr12_init_modes Failed to get primary CRTC info.", "").strip.split("\r\n");
		logInfo("voice: %s", spl[0 .. $]);
		voice = spl[0];
		auto pitches = spl[1].split(' ');
		defPitch = to!ushort(pitches[0]);
		minPitch = to!ushort(pitches[1]);
		maxPitch = to!ushort(pitches[2]);
		auto speeds = spl[2].split(' ');
		defSpeed = to!ushort(speeds[0]);
		minSpeed = to!ushort(speeds[1]);
		maxSpeed = to!ushort(speeds[2]);
	}
}

SAM[string] SAMS;

void main(string[] args)
{
	auto router = new URLRouter;
	router.registerWebInterface(new SAMService);
	router.get("/*", serveStaticFiles("public/"));

	auto proc = execute("sapi4limits.exe");
	if (proc.status != 0) {
		logError("sapi4limits fail");
		exit(1);
	}
	auto voices = proc.output.replace("err:xrandr:xrandr12_init_modes Failed to get primary CRTC info.", "").strip.split("\r\n");
	foreach (voice; voices) {
		SAMS[voice] = SAM(voice);
	}

	auto settings = new HTTPServerSettings;
	settings.port = 23451;
	settings.bindAddresses = [ "127.0.0.1" ];
	listenHTTP(settings, router);

	runApplication();
}

class SAMService
{
	@path("/")
	void getIndex(HTTPServerRequest req, HTTPServerResponse res)
	{
		auto voices = SAMS.keys.sort;
		render!("index.dt", voices);
	}

	@path("/VoiceLimitations")
	void getVoiceLimitations(HTTPServerRequest req, HTTPServerResponse res)
	{
		string voice;
		if ((voice = req.query.get("voice", "")) == "" || !SAMS.keys.canFind(voice)) {
			res.writeBody("Invalid voice", HTTPStatus.badRequest);
			return;
		}

		auto s = SAMS[voice];
		res.writeJsonBody([
			"defPitch": s.defPitch,
			"minPitch": s.minPitch,
			"maxPitch": s.maxPitch,
			"defSpeed": s.defSpeed,
			"minSpeed": s.minSpeed,
			"maxSpeed": s.maxSpeed
		]);
	}

	@path("/SAPI4")
	void getSAPI4(HTTPServerRequest req, HTTPServerResponse res)
	{
		try {
			string text = req.query.get("text", "");

			if (text == "" || text.length > 4095) {
				res.writeBody("Invalid text", 400);
				return;
			}

			int pitch;
			long speed;
			try {
				pitch = to!int(req.query.get("pitch", "-1"));
				speed = to!long(req.query.get("speed", "-1"));
			} catch (Exception) {
				res.writeBody("Invalid pitch/speed", 400);
				return;
			}

			string voice = req.query.get("voice", "INVALID");
			if (!SAMS.keys.canFind(voice)) {
				res.writeBody("Invalid voice", 400);
				return;
			}
			auto sam = SAMS[voice];

			if (pitch == -1)
				pitch = sam.defPitch;
			if (speed == -1)
				speed = sam.defSpeed;

			if (pitch > sam.maxPitch || pitch < sam.minPitch) {
				res.writeBody("Available pitch: [" ~ to!string(sam.minPitch) ~ "; " ~ to!string(sam.maxPitch) ~ "], got " ~ to!string(pitch), 400);
				return;
			}

			if (speed > sam.maxSpeed || speed < sam.minSpeed) {
				res.writeBody("Available speed: [" ~ to!string(sam.minSpeed) ~ "; " ~ to!string(sam.maxSpeed) ~ "], got " ~ to!string(speed), 400);
				return;
			}

			uint synthesisSpeed = cast(uint)speed;
			bool restoreRequestedTempo = voice == NIKOLAI_VOICE &&
				speed < sam.maxSpeed && linuxFfmpegAvailable();
			if (restoreRequestedTempo)
				synthesisSpeed = sam.maxSpeed;

			auto proc = pipeProcess(["sapi4out.exe", voice, to!string(pitch), to!string(synthesisSpeed), text], Redirect.all);

			auto executedAt = Clock.currTime;
			auto wait = tryWait(proc.pid);

			while (!wait.terminated && Clock.currTime - executedAt < dur!"seconds"(60)) {
				wait = tryWait(proc.pid);
				sleep(dur!"msecs"(100));
			}

			if (!wait.terminated) {
				kill(proc.pid);
				res.writeBody("Please reformat your text", 400);
				return;
			} else if (wait.status != 0) {
				res.writeBody("Please reformat your text", 400);
				return;
			}
			
			string outputErr;
			foreach (line; proc.stderr.byLine)
				outputErr ~= line.idup;

			string output;
			foreach (line; proc.stdout.byLine)
				output ~= line.idup;
			
			if (outputErr != "")
				logInfo("got error output \"" ~ outputErr ~ "\"");

			auto file = output.replace("err:xrandr:xrandr12_init_modes Failed to get primary CRTC info.", "").strip();

			if (file == "") {
				core.stdc.stdlib.exit(1);
			}

			if (restoreRequestedTempo && !restoreTempo(file, speed, synthesisSpeed)) {
				if (exists(file))
					removeFile(file);
				res.writeBody("Could not restore Nikolai tempo", 500);
				return;
			}

			auto fs = openFile(file, FileMode.read);

			res.contentType = "audio/wav";
			pipe(fs, res.bodyWriter);
			fs.close();
			removeFile(file);
		} catch (Exception ex) {
			logInfo("exception " ~ ex.toString());
		}
	}
}

import Corpus.SuiteResult;
import Exec.ExecResult;
import haxe.io.Bytes;
import haxe.io.Path;
import sys.FileSystem;
import sys.io.File;

using StringTools;

/**
	Haxe's unit suite for HashLink: tests/unit/compile-hl.hxml is built by the compiler under test and by
	Haxe, the two unit.hl files are compared byte for byte (but for the compile date unit.TestMain bakes
	in), and both are run on hl.exe.
**/
class UnitHl {
	static inline var DATE_LENGTH = 19;

	static function isDigit(b:Bytes, i:Int):Bool {
		var c = b.get(i);
		return c >= 48 && c <= 57;
	}

	/** Whether the 19 bytes at `at` read `YYYY-MM-DD hh:mm:ss`. **/
	static function isDate(b:Bytes, at:Int):Bool {
		if (at < 0 || at + DATE_LENGTH > b.length) return false;
		for (i in 0...DATE_LENGTH) {
			var c = b.get(at + i);
			var ok = switch (i) {
				case 4 | 7: c == "-".code;
				case 10: c == " ".code;
				case 13 | 16: c == ":".code;
				default: isDigit(b, at + i);
			}
			if (!ok) return false;
		}
		return true;
	}

	/** The index of the first byte where the two differ, or -1 when they are the same. **/
	public static function firstDifference(a:Bytes, b:Bytes):Int {
		var n = a.length < b.length ? a.length : b.length;
		for (i in 0...n)
			if (a.get(i) != b.get(i)) return i;
		return a.length == b.length ? -1 : n;
	}

	/** True when the lengths are equal and every differing byte lies in one window that is a date on both sides. **/
	public static function sameExceptDate(a:Bytes, b:Bytes):Bool {
		if (a.length != b.length) return false;
		var first = firstDifference(a, b);
		if (first < 0) return true;
		var last = a.length - 1;
		while (a.get(last) == b.get(last)) last--;
		var from = last - DATE_LENGTH + 1;
		for (start in (from > 0 ? from : 0)...first + 1)
			if (isDate(a, start) && isDate(b, start)) return true;
		return false;
	}

	/** A launch failure is not a run: no process, a shell's 126/127, or a Windows loader status (0xC0000000 and up, which no hl exit code reaches). **/
	static function launchFailed(r:ExecResult):Bool
		return r.code < 0 || r.code == 126 || r.code == 127 || r.code > 255 || r.output.startsWith("<could not start");

	static function normalise(output:String):String
		return [for (line in output.replace("\r\n", "\n").split("\n")) if (line.indexOf("Generated at:") < 0 && !line.startsWith("execution time:")) line].join("\n");

	static inline var UTEST_PIN = "a94f8812e8786f2b5fec52ce9f26927591d26327";

	/**
		Haxe 4.3.7's CI runs the unit suite against utest at UTEST_PIN (tests/RunCi.hx); the utest that
		`haxelib` has installed is usually newer (UTest 2 changed the `type` of Assert.raises to Any, which the
		suite's `exc` helper trips over). Exports the pin from the installed utest's git checkout into a cache
		under the temp root and returns a haxelib repository in which `utest` is a dev directory at the export,
		for HAXELIB_PATH; null (with the reason in `why[0]`) when that is not possible. Nothing installed is changed.
	**/
	static function pinnedUtestRepo(env:Map<String, String>, unitDir:String, why:Array<String>):Null<String> {
		var cache = Path.join([Exec.tempRoot(), "haxe-conformance-utest-" + UTEST_PIN.substr(0, 7)]);
		var repo = Path.join([cache, "repo"]);
		var src = Path.join([cache, "utest"]);
		if (FileSystem.exists(Path.join([src, "haxelib.json"])) && FileSystem.exists(Path.join([repo, "utest", ".dev"]))) {
			// A reused cache must still be at the pin: put it back if it moved, rebuild it if that fails.
			if (checkedOut(src, env) == UTEST_PIN) return repo;
			Exec.run("git", ["-C", src, "checkout", "-q", UTEST_PIN], env);
			if (checkedOut(src, env) == UTEST_PIN) return repo;
		}
		var lib = Exec.run("haxelib", ["libpath", "utest"], env, unitDir);
		var installed = lib.output.trim();
		if (lib.code != 0 || installed == "" || !FileSystem.exists(installed)) {
			why.push("haxelib has no utest to take the pin from: " + installed);
			return null;
		}
		cleanup(cache);
		Exec.mkdirs(Path.join([repo, "utest"]));
		var steps = [
			["clone", "-q", "--no-checkout", installed, src],
			["-C", src, "checkout", "-q", UTEST_PIN]
		];
		for (a in steps) {
			var r = Exec.run("git", a, env);
			if (r.code != 0) {
				why.push("git " + a.join(" ") + " failed: " + r.output.trim());
				cleanup(cache);
				return null;
			}
		}
		if (checkedOut(src, env) != UTEST_PIN) {
			why.push("the utest cache is not at " + UTEST_PIN.substr(0, 7) + " after checkout");
			cleanup(cache);
			return null;
		}
		File.saveContent(Path.join([repo, "utest", ".dev"]), src.replace("\\", "/"));
		return repo;
	}

	static function checkedOut(dir:String, env:Map<String, String>):String {
		var r = Exec.run("git", ["-C", dir, "rev-parse", "HEAD"], env);
		return r.code == 0 ? r.output.trim() : "";
	}

	static function cleanup(dir:String) {
		try Exec.removeTree(dir) catch (_:Dynamic) {}
	}

	public static function run(compiler:Null<String>, haxe:Null<String>, std:Null<String>, hlExe:String, testsDir:String):SuiteResult {
		// The compiles create tests/unit/bin; take it away again if it was not there and is empty.
		var bin = Path.join([testsDir, "unit", "bin"]);
		var binExisted = FileSystem.exists(bin);
		var r = runSuite(compiler, haxe, std, hlExe, testsDir);
		try if (!binExisted && FileSystem.exists(bin) && FileSystem.isDirectory(bin) && FileSystem.readDirectory(bin).length == 0) FileSystem.deleteDirectory(bin) catch (_:Dynamic) {}
		return r;
	}

	static function runSuite(compiler:Null<String>, haxe:Null<String>, std:Null<String>, hlExe:String, testsDir:String):SuiteResult {
		var t0 = Sys.time();
		function result(ok:Bool, note:String):SuiteResult {
			Sys.println('=== unit-hl: ' + (ok ? "PASS" : "FAIL") + '  ($note)');
			Sys.println("");
			return {name: "unit-hl", ok: ok, seconds: Sys.time() - t0, note: note};
		}
		Sys.println("=== unit-hl: compile-hl.hxml with Haxe and with the compiler, compare unit.hl, run both  (tests/unit)");
		if (haxe == null) return result(false, "--haxe is required");
		if (compiler == null) return result(false, "--compiler is required");
		if ((hlExe.indexOf("/") >= 0 || hlExe.indexOf("\\") >= 0) && !FileSystem.exists(hlExe))
			return result(false, 'hl.exe not found: $hlExe');

		var sep = Exec.isWindows ? ";" : ":";
		var basePath = Sys.getEnv("PATH");
		if (Path.directory(haxe) == "") {
			// A bare name is looked up on PATH the way the OS would.
			var found:Null<String> = null;
			for (d in basePath.split(sep))
				for (name in (Exec.isWindows ? [haxe, haxe + ".exe"] : [haxe])) {
					var p = Path.join([d == "" ? "." : d, name]);
					if (found == null && FileSystem.exists(p) && !FileSystem.isDirectory(p)) found = p;
				}
			if (found == null) return result(false, 'Haxe not found on PATH: $haxe');
			haxe = FileSystem.fullPath(found);
		}
		var referenceDir = FileSystem.fullPath(Path.directory(haxe));
		// Both compilers get the same PATH (the reference Haxe first, so its haxelib and utest are found the
		// same way) and the same HAXE_STD_PATH (--std, or the std beside the reference), so the debug file
		// tables of the two unit.hl files match.
		var path = referenceDir + sep + basePath;
		var stdPath = std != null ? std : Path.join([referenceDir, "std"]);
		var unitDir = Path.join([testsDir, "unit"]);
		var scratch = Path.join([Exec.tempRoot(), "haxe-conformance-unit-hl-" + Std.random(0x7FFFFFF)]);
		Exec.mkdirs(scratch);
		var why:Array<String> = [];
		var utestRepo = pinnedUtestRepo(["PATH" => path, "HAXE_STD_PATH" => stdPath], unitDir, why);
		if (utestRepo == null) {
			cleanup(scratch);
			return result(false, "cannot get utest " + UTEST_PIN.substr(0, 7) + ": " + why[0]);
		}
		Sys.println("utest " + UTEST_PIN.substr(0, 7) + " (Haxe 4.3.7 CI pin), from " + utestRepo);
		var built = Path.join([unitDir, "bin", "unit.hl"]);
		try {
			// compile-hl.hxml without its hl-check line, kept outside tests/.
			var src = File.getContent(Path.join([unitDir, "compile-hl.hxml"])).replace("\r", "");
			var lines = [for (l in src.split("\n")) if (l.indexOf("hl-check") < 0) l];
			var hxml = Path.join([scratch, "unit-hl.hxml"]);
			File.saveContent(hxml, lines.join("\n") + "\n");

			var copies:Array<String> = [];
			var builds = [
				{label: "Haxe", dir: "haxe", exe: haxe},
				{label: "the compiler", dir: "compiler", exe: compiler}
			];
			for (b in builds) {
				if (FileSystem.exists(built)) FileSystem.deleteFile(built);
				Sys.println('--- ${b.label}: ${b.exe} $hxml');
				var env = ["PATH" => path, "HAXE_STD_PATH" => stdPath, "HAXELIB_PATH" => utestRepo];
				var got = Exec.run(b.exe, [hxml], env, unitDir);
				if (got.timedOut) {
					if (FileSystem.exists(built)) FileSystem.deleteFile(built);
					cleanup(scratch);
					return result(false, b.dir == "haxe" ? "Haxe timed out" : "the compiler timed out");
				}
				Sys.println(got.output.trim());
				if (got.code != 0 || !FileSystem.exists(built)) {
					if (FileSystem.exists(built)) FileSystem.deleteFile(built);
					cleanup(scratch);
					return result(false, b.dir == "haxe" ? 'Haxe failed (exit ${got.code})' : 'the compiler failed (exit ${got.code})');
				}
				var copy = Path.join([scratch, b.dir]);
				Exec.mkdirs(copy);
				File.copy(built, Path.join([copy, "unit.hl"]));
				copies.push(copy);
			}
			if (FileSystem.exists(built)) FileSystem.deleteFile(built);

			var theirs = File.getBytes(Path.join([copies[0], "unit.hl"]));
			var ours = File.getBytes(Path.join([copies[1], "unit.hl"]));
			if (!sameExceptDate(theirs, ours)) {
				var at = "byte " + firstDifference(theirs, ours);
				cleanup(scratch);
				return result(false, "unit.hl differs from Haxe's at " + at);
			}

			// As tests/runci/targets/Hl.hx runs it: from tests/unit, so only the loaded unit.hl differs.
			var ran = [for (d in copies) Exec.run(hlExe, [Path.join([d, "unit.hl"])], new Map(), unitDir)];
			for (i in 0...2)
				if (ran[i].timedOut) {
					cleanup(scratch);
					return result(false, "unit.hl timed out (" + (i == 0 ? "haxe" : "compiler") + ")");
				}
			for (r in ran)
				if (launchFailed(r)) {
					cleanup(scratch);
					return result(false, 'hl.exe could not run unit.hl (exit ${r.code})');
				}
			for (i in 0...2) {
				var summary = ~/^successes: \d+\r?\nerrors: (\d+)\r?\nfailures: (\d+)/m;
				Sys.println((i == 0 ? "Haxe" : "the compiler") + ": " + (summary.match(ran[i].output)
					? summary.matched(1) + " errors, " + summary.matched(2) + " failures" : "no test summary in the output") + " (exit " + ran[i].code + ")");
			}
			var same = ran[0].code == ran[1].code && normalise(ran[0].output) == normalise(ran[1].output);
			cleanup(scratch);
			return same ? result(true, "unit.hl identical; runs as Haxe's does (exit " + ran[0].code + ")") : result(false, "runs differently from Haxe's");
		} catch (e:Dynamic) {
			if (FileSystem.exists(built)) try FileSystem.deleteFile(built) catch (_:Dynamic) {}
			cleanup(scratch);
			return result(false, "error: " + Std.string(e));
		}
	}
}

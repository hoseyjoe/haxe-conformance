import haxe.io.Bytes;

/** Checks UnitHl.sameExceptDate. Run: haxe -cp harness --run UnitHlCheck **/
class UnitHlCheck {
	static var failures = 0;

	static function expect(name:String, got:Bool, want:Bool) {
		if (got != want) {
			failures++;
			Sys.println('FAIL  $name');
		} else
			Sys.println('ok    $name');
	}

	static function make(s:String):Bytes
		return Bytes.ofString(s);

	static function main() {
		var base = "head--2026-11-10 12:34:56--tail--0123456789";
		var other = "head--2025-01-02 03:04:05--tail--0123456789";
		expect("identical", UnitHl.sameExceptDate(make(base), make(base)), true);
		expect("only the date differs", UnitHl.sameExceptDate(make(base), make(other)), true);
		expect("one digit of the date differs", UnitHl.sameExceptDate(make(base), make("head--2026-11-10 12:34:57--tail--0123456789")), true);
		expect("date and one other byte", UnitHl.sameExceptDate(make(base), make("head--2025-01-02 03:04:05--tail--0123456780")), false);
		expect("date and a byte before it", UnitHl.sameExceptDate(make(base), make("hexd--2025-01-02 03:04:05--tail--0123456789")), false);
		expect("one byte outside any date", UnitHl.sameExceptDate(make(base), make("head--2026-11-10 12:34:56--tail--0123456780")), false);
		expect("different lengths", UnitHl.sameExceptDate(make(base), make(base + "x")), false);
		expect("window not a date on one side", UnitHl.sameExceptDate(make(base), make("head--2026-11-10 12:34:5x--tail--0123456789")), false);
		expect("window not a date on either side",
			UnitHl.sameExceptDate(make("head--abcdefghijklmnopqrs--tail"), make("head--ABCDEFGHIJKLMNOPQRS--tail")), false);
		expect("two dates differ", UnitHl.sameExceptDate(make(base + base), make(other + other)), false);
		Sys.println(failures == 0 ? "UnitHlCheck: PASS" : "UnitHlCheck: FAIL");
		Sys.exit(failures == 0 ? 0 : 1);
	}
}

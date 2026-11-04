local guard = require("neostar.fstar.guard")

local ST = "let lem (x:nat) : Lemma (x + 0 == x) = "

local function check(helpers, body)
  return guard.check_candidate(ST, helpers or "", body)
end

describe("candidate guard", function()
  it("accepts an ordinary proof and helper", function()
    assert.is_nil(check("", "()"))
    assert.is_nil(check("let aux (y:nat) : Lemma (y >= 0) = ()", "aux x; ()"))
    assert.is_nil(check("", "assert (x + 0 == x);\n  ()"))
  end)

  it("rejects admit and its variants anywhere, qualified or not", function()
    assert.matches("`admit`", check("", "admit ()"), 1, true)
    assert.matches("`admit`", check("", "FStar.Pervasives.admit ()"), 1, true)
    assert.matches("`admit_smt_queries`", check("", "admit_smt_queries ()"), 1, true)
    assert.matches("`tadmit`", check("", "FStar.Tactics.tadmit ()"), 1, true)
    assert.matches("`admit_termination`", check("[@@admit_termination] let rec f (n:nat) : nat = f n", "()"), 1, true)
    assert.matches("`magic`", check("", "magic ()"), 1, true)
    assert.matches("`unsafe_coerce`", check("", "unsafe_coerce ()"), 1, true)
  end)

  it("rejects assume val and expect_failure in helpers", function()
    assert.matches("`assume`", check("assume val ax : squash False", "()"), 1, true)
    assert.matches("`expect_failure`", check("[@@expect_failure] let bad : squash False = ()", "()"), 1, true)
  end)

  it("ignores denied words inside comments and strings", function()
    assert.is_nil(check("", "(* we do not admit anything here *) ()"))
    assert.is_nil(check("", "// no admit\n  ()"))
    assert.is_nil(check("", 'let _ = "admit" in ()'))
    assert.is_nil(check("", "(* nested (* admit *) comment *) ()"))
  end)

  it("allows #push-options with allowed options only", function()
    assert.is_nil(check('#push-options "--z3rlimit 50 --fuel 2 --ifuel 1"\nlet aux (y:nat) : Lemma (y >= 0) = ()\n#pop-options', "()"))
    assert.matches("--admit_smt_queries", check('#push-options "--admit_smt_queries true"\nlet a = 1\n#pop-options', "()"), 1, true)
    assert.matches("--lax", check('#push-options "--lax"\nlet a = 1\n#pop-options', "()"), 1, true)
    assert.matches("#set-options", check('#set-options "--z3rlimit 5"', "()"), 1, true)
    assert.matches("#reset-options", check("#reset-options", "()"), 1, true)
    assert.matches("matching #pop-options", check('#push-options "--z3rlimit 5"\nlet a = 1', "()"), 1, true)
    assert.matches("without a matching", check("#pop-options", "()"), 1, true)
  end)

  it("rejects module and friend in helpers", function()
    assert.matches("`module`", check("module X", "()"), 1, true)
    assert.matches("`friend`", check("friend Y", "()"), 1, true)
  end)

  it("rejects a body that adds declarations after the target", function()
    assert.matches("single expression", check("", "()\n\nlet sneaky : nat = 1"), 1, true)
    assert.matches("empty", check("", "  "), 1, true)
  end)
end)

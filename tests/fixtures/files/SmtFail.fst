module SmtFail

let ok (x:nat) : Lemma (x >= 0) = ()

let bad (x:nat) : Lemma (x > 5) = ()

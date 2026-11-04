module Prove

let bad_prefix (x:nat) : Lemma (x + 1 == x) = ()

let ok_prefix (x:nat) : Lemma (x + 0 == x) = ()

val target : x:nat -> Lemma (x * 1 + 0 == x)
let target x =
  admit ()

let after (x:nat) : Lemma (x >= 0) = ()

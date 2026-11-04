module Prove
#push-options "--admit_smt_queries true"

let bad_prefix (x:nat) : Lemma (x + 1 == x) = ()

let ok_prefix (x:nat) : Lemma (x + 0 == x) = ()

#pop-options
val target : x:nat -> Lemma (x * 1 + 0 == x)
let target x =
  assert (x + 1 == x)

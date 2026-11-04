module Decls

let one (x:nat) : Lemma (x + 0 == x) = ()

val two : x:nat -> Lemma (x * 1 == x)
let two x =
  assert (x * 1 == x);
  ()

let rec fact (n:nat) : nat = if n = 0 then 1 else n * fact (n - 1)

type color = | Red | Green

let rec ev (n:nat) : bool = if n = 0 then true else od (n - 1)
and od (n:nat) : bool = if n = 0 then false else ev (n - 1)

[@@"opaque_to_smt"]
let three (x:nat)
  : Lemma (ensures x + 0 == x)
  = admit ()

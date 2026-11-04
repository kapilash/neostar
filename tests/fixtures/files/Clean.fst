module Clean

let double (x:int) : int = x + x

let lemma_double (x:int) : Lemma (double x == 2 * x) = ()

(** The length of a list *)
let len (#a:Type) (l:list a) : nat = List.Tot.length l

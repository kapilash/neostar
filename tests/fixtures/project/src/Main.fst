module Main

open Lib

let two : nat = succ 1

let lemma_two () : Lemma (two == 2) = ()

let three : nat = succ two

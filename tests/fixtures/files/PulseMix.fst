module PulseMix

let fn = 1

#lang-pulse
open Pulse

fn incr (r:ref int)
  requires pts_to r 'v
  ensures pts_to r ('v + 1)
{
  r := !r + 1
}

#lang-fstar

let after (x:int) : int = x

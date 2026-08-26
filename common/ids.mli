(** Validated identifier types. Identifiers are abstract types with validated
    constructors; raw strings never become storage paths (§11.2, §35.2). *)

module type SLUG = sig
  type t = private string
  val label : string
  val of_string : string -> (t, Error.Validation.t) result
  val of_string_exn : string -> t
  val to_string : t -> string
  val compare : t -> t -> int
  val equal : t -> t -> bool
  val hash : t -> int
end

module Function_name : SLUG
module Tenant_id    : SLUG
module Alias         : SLUG
module Store_id       : SLUG
module Log_stream     : SLUG
module Qualifier      : SLUG

(** A JS-identifier-like binding name (camelCase allowed, §15.2/§10.2). *)
module Binding_name : sig
  type t = private string
  val label : string
  val of_string : string -> (t, Error.Validation.t) result
  val of_string_exn : string -> t
  val to_string : t -> string
  val compare : t -> t -> int
  val equal : t -> t -> bool
  val hash : t -> int
end

module Digest : sig
  (** 64 lowercase hex chars *)
  type t = private string
  val label : string
  val of_string : string -> (t, Error.Validation.t) result
  val to_string : t -> string
  val compare : t -> t -> int
  val equal : t -> t -> bool
  (** Constant-time equality for digest comparison (§10.4). *)
  val constant_time_equal : t -> t -> bool
end

module Revision_id : sig
  type t = Digest.t
  val of_string : string -> (t, Error.Validation.t) result
  val to_string : t -> string
  val compare : t -> t -> int
  val equal : t -> t -> bool
  val constant_time_equal : t -> t -> bool
end

module Key_prefix : sig
  type t = private string
  val of_string : string -> (t, Error.Validation.t) result
  val to_string : t -> string
  val compare : t -> t -> int
  val equal : t -> t -> bool
end

module Module_path : sig
  type t = private string
  val of_string : string -> (t, Error.Validation.t) result
  val to_string : t -> string
  val compare : t -> t -> int
  val equal : t -> t -> bool
end

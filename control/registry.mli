(** Function revision registry (§20.4). Phase 4: in-memory + checkpoint. *)

type revision = {
  digest : Ids.Digest.t;
  manifest_json : string;
  runtime : string;
  created_at : string;
}

type t

val make : ?checkpoint_path:string -> unit -> t
val publish_revision :
  t -> tenant:Ids.Tenant_id.t -> function_name:Ids.Function_name.t ->
  revision:revision -> (unit, Error.t) result

(** Resolve (tenant, function, qualifier) -> revision. Qualifier is a digest or
    an alias; returns the revision or a [Not_found]/[Conflict] error. *)
val resolve :
  t -> tenant:Ids.Tenant_id.t -> function_name:Ids.Function_name.t ->
  qualifier:Ids.Qualifier.t -> (Ids.Revision_id.t, Error.t) result

(** §20.4: alias movement with optional compare-and-set precondition. *)
val move_alias :
  t -> tenant:Ids.Tenant_id.t -> function_name:Ids.Function_name.t ->
  alias:Ids.Alias.t -> revision:Ids.Revision_id.t ->
  precondition:Ids.Revision_id.t option -> (unit, Error.t) result

val checkpoint_save : t -> (unit, string) result
val checkpoint_load : string -> (t, string) result
val revision_to_json : revision -> Yojson.Safe.t
val revision_of_json : Yojson.Safe.t -> (revision, string) result

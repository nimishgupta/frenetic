Set Implicit Arguments.

Require Import Coq.Lists.List.
Require Import Coq.Structures.Equalities.
Require Import Common.Types.
Require Import Bag.Bag.

Local Open Scope list_scope.
Local Open Scope equiv_scope.
Local Open Scope bag_scope.

(** Elements of a Featherweight OpenFlow model. *)
Module Type ATOMS.

  Parameter packet : Type.
  Parameter switchId : Type.
  Parameter portId : Type.
  Parameter flowTable : Type.
  Parameter flowMod : Type.

  Inductive fromController : Type :=
  | PacketOut : portId -> packet -> fromController
  | BarrierRequest : nat -> fromController
  | FlowMod : flowMod -> fromController.

  Inductive fromSwitch : Type :=
  | PacketIn : portId -> packet -> fromSwitch
  | BarrierReply : nat -> fromSwitch.

  (** Produces a list of packets to forward out of ports, and a list of packets
      to send to the controller. *)
  Parameter process_packet : flowTable -> portId -> packet -> 
    list (portId * packet) * list packet.

  Parameter modify_flow_table : flowMod -> flowTable -> flowTable.

  Parameter packet_eq_dec : Eqdec packet.
  Parameter switchId_eq_dec : Eqdec switchId.
  Parameter portId_eq_dec : Eqdec portId.
  Parameter flowTable_eq_dec : Eqdec flowTable.
  Parameter flowMod_eq_dec : Eqdec flowMod.

  Section Controller.

    Parameter controller : Type.

    Parameter controller_recv : controller -> switchId -> fromSwitch -> 
      controller -> Prop.

    Parameter controller_step : controller -> controller -> Prop.

    Parameter controller_send : controller ->  controller -> switchId -> 
      fromController -> Prop.

  End Controller.

End ATOMS.

Module ConcreteSemantics (Import Atoms : ATOMS).

  Section DecidableEqualities.

    Hint Resolve packet_eq_dec switchId_eq_dec portId_eq_dec flowTable_eq_dec
      flowMod_eq_dec.

    Lemma fromController_eq_dec : Eqdec fromController.
    Proof.
      unfold Eqdec. decide equality. apply eqdec.
    Qed.

    Lemma fromSwitch_eq_dec : Eqdec fromSwitch.
    Proof.
      unfold Eqdec. decide equality. apply eqdec.
    Qed.

  End DecidableEqualities.

  Instance Packet_Eq : Eq packet.
  Proof.
    split. apply packet_eq_dec.
  Qed.

  Instance PortId_Eq : Eq portId.
  Proof.
    split. apply portId_eq_dec.
  Qed.

  Instance SwitchId_Eq : Eq switchId.
  Proof.
    split. apply switchId_eq_dec.
  Qed.

  Instance FromController_Eq : Eq fromController.
  Proof.
    split. apply fromController_eq_dec.
  Qed.

  Instance FromSwitch_Eq : Eq fromSwitch.
  Proof.
    split. apply fromSwitch_eq_dec.
  Qed.

  Record switch := Switch {
    switch_swichId : switchId;
    switch_ports : list portId;
    switch_flowTable : flowTable;
    switch_inputPackets : Bag.bag (portId * packet);
    switch_outputPackets :  Bag.bag (portId * packet);
    switch_fromController : Bag.bag fromController;
    switch_fromSwitch : Bag.bag fromSwitch
  }.
  
  Record dataLink := DataLink {
    dataLink_src : switchId * portId;
    dataList_packets : list packet;
    dataLink_dst : switchId * portId
  }.
  
  Record openFlowLink := OpenFlowLink {
    openFlowLink_to : switchId;
    openFlowLink_fromSwitch : list fromSwitch;
    openFlowLink_fromController : list fromController
  }.

  Definition observation := (switchId * portId * packet) %type.

  (* NOTE(arjun): Ask me in person why exactly I picked these levels. *)
  Reserved Notation "SwitchStep[ sw ; obs ; sw0 ]"
    (at level 70, no associativity).
  Reserved Notation "ControllerOpenFlow[ c ; l ; obs ; c0 ; l0 ]"
    (at level 70, no associativity).
  Reserved Notation "TopoStep[ sw ; link ; obs ; sw0 ; link0 ]"
    (at level 70, no associativity).

  Inductive NotBarrierRequest : fromController -> Prop :=
  | PacketOut_NotBarrierRequest : forall pt pk,
      NotBarrierRequest (PacketOut pt pk)
  | FlowMod_NotBarrierRequest : forall fm,
      NotBarrierRequest (FlowMod fm).

  (** Devices of the same type do not interact in a single
      step. Therefore, we never have to permute the lists below. If we
      instead had just one list of all devices, we would have to worry
      about permuting the list or define symmetric step-rules. *)
  Record state := State {
    state_switches : list switch;
    state_dataLinks : list dataLink;
    state_openFlowLinks : list openFlowLink;
    state_controller : controller
  }.
    
  Inductive step : state -> option observation -> state -> Prop :=
  | PktProcess : forall swId pts tbl pt pk inp outp ctrlm switchm outp'
                        pksToCtrl,
    process_packet tbl pt pk = (outp', pksToCtrl) ->
    SwitchStep[
      (Switch swId pts tbl ({|(pt,pk)|} <+> inp) outp 
         ctrlm switchm);
      (Some (swId,pt,pk));
      (Switch swId pts tbl inp (Bag.FromList outp' <+> outp) 
         ctrlm (Bag.FromList (map (PacketIn pt) pksToCtrl) <+> switchm))]
  | ModifyFlowTable : forall swId pts tbl inp outp fm ctrlm switchm,
    SwitchStep[
      (Switch swId pts tbl inp outp 
         ({|FlowMod fm|} <+> ctrlm) switchm);
      None;
      (Switch swId pts (modify_flow_table fm tbl) inp outp 
         ctrlm switchm)]
  | SendPacketOut : forall pt pts swId tbl inp outp pk ctrlm switchm,
    In pt pts ->
    SwitchStep[
      (Switch swId pts tbl inp outp  ({|PacketOut pt pk|} <+> ctrlm) switchm);
      None;
      (Switch swId pts tbl inp ({| (pt,pk) |} <+> outp) ctrlm switchm)]
  | SendDataLink : forall swId pts tbl inp pt pk outp ctrlm switchm pks dst,
    TopoStep[
      (Switch swId pts tbl inp ({|(pt,pk)|} <+> outp) ctrlm switchm);
      (DataLink (swId,pt) pks dst);
      None;
      (Switch swId pts tbl inp outp ctrlm switchm);
      (DataLink (swId,pt) (pk :: pks) dst)]
  | RecvDataLink : forall swId pts tbl inp outp ctrlm switchm src pks pk pt,
    TopoStep[
      (Switch swId pts tbl inp outp ctrlm switchm);
      (DataLink src  (pks ++ [pk]) (swId,pt));
      None;
      (Switch swId pts tbl ({|(pt,pk)|} <+> inp) outp ctrlm switchm);
      (DataLink src pks (swId,pt))]
  | Step_controller : forall sws links ofLinks ctrl ctrl',
      controller_step ctrl ctrl' ->
      step (State sws links ofLinks ctrl)
           None
           (State sws links ofLinks ctrl')
  | ControllerRecv : forall ctrl msg ctrl' swId fromSwitch fromCtrl,
    controller_recv ctrl swId msg ctrl' ->
    ControllerOpenFlow[
      ctrl ;
      (OpenFlowLink swId (fromSwitch ++ [msg]) fromCtrl) ;
       None ;
      ctrl' ;
      (OpenFlowLink swId fromSwitch fromCtrl) ]
  | ControllerSend : forall ctrl msg ctrl' swId fromSwitch fromCtrl,
    controller_send ctrl ctrl' swId msg ->
    ControllerOpenFlow[
      ctrl ;
      (OpenFlowLink swId fromSwitch fromCtrl);
      None;
      ctrl';
      (OpenFlowLink swId fromSwitch (msg :: fromCtrl)) ]
  | SendToController : forall swId pts tbl inp outp ctrlm msg switchm fromSwitch
      fromCtrl sws sws0 links ofLinks ofLinks0 ctrl,
    step
      (State
        (sws ++ (Switch swId pts tbl inp outp ctrlm ({| msg |} <+> switchm))
          :: sws0)
        links
        (ofLinks ++ (OpenFlowLink swId fromSwitch fromCtrl) :: ofLinks0)
        ctrl)
      None
      (State
        (sws ++ (Switch swId pts tbl inp outp ctrlm switchm) :: sws0)
        links
        (ofLinks ++ (OpenFlowLink swId (msg :: fromSwitch) fromCtrl) 
          :: ofLinks0)
        ctrl)
  | RecvBarrier : forall swId pts tbl inp outp switchm fromSwitch fromCtrl
      xid sws sws0 links ofLinks ofLinks0 ctrl,
    step
      (State
        (sws ++ (Switch swId pts tbl inp outp Bag.Empty switchm) :: sws0)
        links
        (ofLinks ++ 
          (OpenFlowLink swId fromSwitch (fromCtrl ++ [BarrierRequest xid])) ::
          ofLinks0)
        ctrl)
      None
      (State
        (sws ++ (Switch swId pts tbl inp outp Bag.Empty
                        ({| BarrierReply xid |} <+> switchm)) :: sws0)
        links
        (ofLinks ++ (OpenFlowLink swId fromSwitch fromCtrl) :: ofLinks0)
        ctrl)
  | RecvFromController : forall swId pts tbl inp outp ctrlm switchm
      fromSwitch fromCtrl (msg : fromController) sws sws0 links ofLinks 
      ofLinks0 ctrl,
    NotBarrierRequest msg ->
    step
      (State
        (sws ++ (Switch swId pts tbl inp outp ctrlm switchm) :: sws0)
        links
        (ofLinks ++ (OpenFlowLink swId fromSwitch (fromCtrl ++ [msg])) :: 
           ofLinks0)
        ctrl)
      None
      (State
        (sws ++ 
           (Switch swId pts tbl inp outp ({| msg |} <+> ctrlm) switchm) :: sws0)
        links
        (ofLinks ++ (OpenFlowLink swId fromSwitch fromCtrl) ::
           ofLinks0)
        ctrl)
      where
  "ControllerOpenFlow[ c ; l ; obs ; c0 ; l0 ]" := 
    (forall sws links ofLinks ofLinks',
      step (State sws links (ofLinks ++ l :: ofLinks') c) 
           obs 
           (State sws links (ofLinks ++ l0 :: ofLinks') c0))
    and
  "TopoStep[ sw ; link ; obs ; sw0 ; link0 ]" :=
    (forall sws sws0 links links0 ofLinks ctrl,
      step 
      (State (sws ++ sw :: sws0) (links ++ link :: links0) ofLinks ctrl)
      obs
      (State (sws ++ sw0 :: sws0) (links ++ link0 :: links0) ofLinks ctrl))
    and
  "SwitchStep[ sw ; obs ; sw0 ]" :=
    (forall sws sws0 links ofLinks ctrl,
      step 
        (State (sws ++ sw :: sws0) links ofLinks ctrl)
        obs
        (State (sws ++ sw0 :: sws0) links ofLinks ctrl)).




End ConcreteSemantics.
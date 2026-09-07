defmodule MmoContracts.Session do
  @moduledoc "现行 Session 协议值；会话状态和鉴权仍属于 Gate。入场位置沿用旧 UE/cm。"
  @type request ::
          {:auth_request, binary(), binary(), non_neg_integer()}
          | {:enter_scene, non_neg_integer(), non_neg_integer()}
          | {:heartbeat, non_neg_integer()}
  @type reply ::
          {:result, :ok | :error, non_neg_integer()}
          | {:enter_scene_result, :ok, non_neg_integer(), {float(), float(), float()},
             non_neg_integer()}
          | {:enter_scene_result, :error, non_neg_integer()}
          | {:heartbeat_reply, non_neg_integer()}
end

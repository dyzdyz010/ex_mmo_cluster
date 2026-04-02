# credo:disable-for-this-file
[
  defmodule Reply.StatusCode do
    @moduledoc false
    (
      defstruct []

      (
        @spec default() :: :ok
        def default() do
          :ok
        end
      )

      @spec encode(atom()) :: integer() | atom()
      [
        (
          def encode(:ok) do
            0
          end

          def encode("ok") do
            0
          end
        ),
        (
          def encode(:error) do
            1
          end

          def encode("error") do
            1
          end
        )
      ]

      def encode(x) do
        x
      end

      @spec decode(integer()) :: atom() | integer()
      [
        def decode(0) do
          :ok
        end,
        def decode(1) do
          :error
        end
      ]

      def decode(x) do
        x
      end

      @spec constants() :: [{integer(), atom()}]
      def constants() do
        [{0, :ok}, {1, :error}]
      end

      @spec has_constant?(any()) :: boolean()
      (
        [
          def has_constant?(:ok) do
            true
          end,
          def has_constant?(:error) do
            true
          end
        ]

        def has_constant?(_) do
          false
        end
      )
    )
  end,
  defmodule ServerResponse.Status do
    @moduledoc false
    (
      defstruct []

      (
        @spec default() :: :OK
        def default() do
          :OK
        end
      )

      @spec encode(atom()) :: integer() | atom()
      [
        (
          def encode(:OK) do
            0
          end

          def encode("OK") do
            0
          end
        ),
        (
          def encode(:ERROR) do
            1
          end

          def encode("ERROR") do
            1
          end
        )
      ]

      def encode(x) do
        x
      end

      @spec decode(integer()) :: atom() | integer()
      [
        def decode(0) do
          :OK
        end,
        def decode(1) do
          :ERROR
        end
      ]

      def decode(x) do
        x
      end

      @spec constants() :: [{integer(), atom()}]
      def constants() do
        [{0, :OK}, {1, :ERROR}]
      end

      @spec has_constant?(any()) :: boolean()
      (
        [
          def has_constant?(:OK) do
            true
          end,
          def has_constant?(:ERROR) do
            true
          end
        ]

        def has_constant?(_) do
          false
        end
      )
    )
  end,
  defmodule AuthRequest do
    @moduledoc false
    defstruct username: "", code: "", __uf__: []

    (
      (
        @spec encode(struct) :: {:ok, iodata} | {:error, any}
        def encode(msg) do
          try do
            {:ok, encode!(msg)}
          rescue
            e in [Protox.EncodingError, Protox.RequiredFieldsError] -> {:error, e}
          end
        end

        @spec encode!(struct) :: iodata | no_return
        def encode!(msg) do
          [] |> encode_username(msg) |> encode_code(msg) |> encode_unknown_fields(msg)
        end
      )

      []

      [
        defp encode_username(acc, msg) do
          try do
            if msg.username == "" do
              acc
            else
              [acc, "\n", Protox.Encode.encode_string(msg.username)]
            end
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:username, "invalid field value"), __STACKTRACE__
          end
        end,
        defp encode_code(acc, msg) do
          try do
            if msg.code == "" do
              acc
            else
              [acc, "\x1A", Protox.Encode.encode_string(msg.code)]
            end
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:code, "invalid field value"), __STACKTRACE__
          end
        end
      ]

      defp encode_unknown_fields(acc, msg) do
        Enum.reduce(msg.__struct__.unknown_fields(msg), acc, fn {tag, wire_type, bytes}, acc ->
          case wire_type do
            0 ->
              [acc, Protox.Encode.make_key_bytes(tag, :int32), bytes]

            1 ->
              [acc, Protox.Encode.make_key_bytes(tag, :double), bytes]

            2 ->
              len_bytes = bytes |> byte_size() |> Protox.Varint.encode()
              [acc, Protox.Encode.make_key_bytes(tag, :packed), len_bytes, bytes]

            5 ->
              [acc, Protox.Encode.make_key_bytes(tag, :float), bytes]
          end
        end)
      end
    )

    (
      (
        @spec decode(binary) :: {:ok, struct} | {:error, any}
        def decode(bytes) do
          try do
            {:ok, decode!(bytes)}
          rescue
            e in [Protox.DecodingError, Protox.IllegalTagError, Protox.RequiredFieldsError] ->
              {:error, e}
          end
        end

        (
          @spec decode!(binary) :: struct | no_return
          def decode!(bytes) do
            parse_key_value(bytes, struct(AuthRequest))
          end
        )
      )

      (
        @spec parse_key_value(binary, struct) :: struct
        defp parse_key_value(<<>>, msg) do
          msg
        end

        defp parse_key_value(bytes, msg) do
          {field, rest} =
            case Protox.Decode.parse_key(bytes) do
              {0, _, _} ->
                raise %Protox.IllegalTagError{}

              {1, _, bytes} ->
                {len, bytes} = Protox.Varint.decode(bytes)
                {delimited, rest} = Protox.Decode.parse_delimited(bytes, len)
                {[username: delimited], rest}

              {3, _, bytes} ->
                {len, bytes} = Protox.Varint.decode(bytes)
                {delimited, rest} = Protox.Decode.parse_delimited(bytes, len)
                {[code: delimited], rest}

              {tag, wire_type, rest} ->
                {value, rest} = Protox.Decode.parse_unknown(tag, wire_type, rest)

                {[
                   {msg.__struct__.unknown_fields_name,
                    [value | msg.__struct__.unknown_fields(msg)]}
                 ], rest}
            end

          msg_updated = struct(msg, field)
          parse_key_value(rest, msg_updated)
        end
      )

      []
    )

    (
      @spec json_decode(iodata(), keyword()) :: {:ok, struct()} | {:error, any()}
      def json_decode(input, opts \\ []) do
        try do
          {:ok, json_decode!(input, opts)}
        rescue
          e in Protox.JsonDecodingError -> {:error, e}
        end
      end

      @spec json_decode!(iodata(), keyword()) :: struct() | no_return()
      def json_decode!(input, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :decode)

        Protox.JsonDecode.decode!(
          input,
          AuthRequest,
          &json_library_wrapper.decode!(json_library, &1)
        )
      end

      @spec json_encode(struct(), keyword()) :: {:ok, iodata()} | {:error, any()}
      def json_encode(msg, opts \\ []) do
        try do
          {:ok, json_encode!(msg, opts)}
        rescue
          e in Protox.JsonEncodingError -> {:error, e}
        end
      end

      @spec json_encode!(struct(), keyword()) :: iodata() | no_return()
      def json_encode!(msg, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :encode)
        Protox.JsonEncode.encode!(msg, &json_library_wrapper.encode!(json_library, &1))
      end
    )

    (
      @deprecated "Use fields_defs()/0 instead"
      @spec defs() :: %{
              required(non_neg_integer) => {atom, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs() do
        %{1 => {:username, {:scalar, ""}, :string}, 3 => {:code, {:scalar, ""}, :string}}
      end

      @deprecated "Use fields_defs()/0 instead"
      @spec defs_by_name() :: %{
              required(atom) => {non_neg_integer, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs_by_name() do
        %{code: {3, {:scalar, ""}, :string}, username: {1, {:scalar, ""}, :string}}
      end
    )

    (
      @spec fields_defs() :: list(Protox.Field.t())
      def fields_defs() do
        [
          %{
            __struct__: Protox.Field,
            json_name: "username",
            kind: {:scalar, ""},
            label: :optional,
            name: :username,
            tag: 1,
            type: :string
          },
          %{
            __struct__: Protox.Field,
            json_name: "code",
            kind: {:scalar, ""},
            label: :optional,
            name: :code,
            tag: 3,
            type: :string
          }
        ]
      end

      [
        @spec(field_def(atom) :: {:ok, Protox.Field.t()} | {:error, :no_such_field}),
        (
          def field_def(:username) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "username",
               kind: {:scalar, ""},
               label: :optional,
               name: :username,
               tag: 1,
               type: :string
             }}
          end

          def field_def("username") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "username",
               kind: {:scalar, ""},
               label: :optional,
               name: :username,
               tag: 1,
               type: :string
             }}
          end

          []
        ),
        (
          def field_def(:code) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "code",
               kind: {:scalar, ""},
               label: :optional,
               name: :code,
               tag: 3,
               type: :string
             }}
          end

          def field_def("code") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "code",
               kind: {:scalar, ""},
               label: :optional,
               name: :code,
               tag: 3,
               type: :string
             }}
          end

          []
        ),
        def field_def(_) do
          {:error, :no_such_field}
        end
      ]
    )

    (
      @spec unknown_fields(struct) :: [{non_neg_integer, Protox.Types.tag(), binary}]
      def unknown_fields(msg) do
        msg.__uf__
      end

      @spec unknown_fields_name() :: :__uf__
      def unknown_fields_name() do
        :__uf__
      end

      @spec clear_unknown_fields(struct) :: struct
      def clear_unknown_fields(msg) do
        struct!(msg, [{unknown_fields_name(), []}])
      end
    )

    (
      @spec required_fields() :: []
      def required_fields() do
        []
      end
    )

    (
      @spec syntax() :: atom()
      def syntax() do
        :proto3
      end
    )

    [
      @spec(default(atom) :: {:ok, boolean | integer | String.t() | float} | {:error, atom}),
      def default(:username) do
        {:ok, ""}
      end,
      def default(:code) do
        {:ok, ""}
      end,
      def default(_) do
        {:error, :no_such_field}
      end
    ]

    (
      @spec file_options() :: nil
      def file_options() do
        nil
      end
    )
  end,
  defmodule Broadcast.Player.Action do
    @moduledoc false
    defstruct action: nil, __uf__: []

    (
      (
        @spec encode(struct) :: {:ok, iodata} | {:error, any}
        def encode(msg) do
          try do
            {:ok, encode!(msg)}
          rescue
            e in [Protox.EncodingError, Protox.RequiredFieldsError] -> {:error, e}
          end
        end

        @spec encode!(struct) :: iodata | no_return
        def encode!(msg) do
          [] |> encode_action(msg) |> encode_unknown_fields(msg)
        end
      )

      [
        defp encode_action(acc, msg) do
          case msg.action do
            nil -> acc
            {:player_enter, _field_value} -> encode_player_enter(acc, msg)
            {:player_leave, _field_value} -> encode_player_leave(acc, msg)
            {:player_move, _field_value} -> encode_player_move(acc, msg)
          end
        end
      ]

      [
        defp encode_player_enter(acc, msg) do
          try do
            {_, child_field_value} = msg.action
            [acc, "\n", Protox.Encode.encode_message(child_field_value)]
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:player_enter, "invalid field value"),
                      __STACKTRACE__
          end
        end,
        defp encode_player_leave(acc, msg) do
          try do
            {_, child_field_value} = msg.action
            [acc, "\x12", Protox.Encode.encode_message(child_field_value)]
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:player_leave, "invalid field value"),
                      __STACKTRACE__
          end
        end,
        defp encode_player_move(acc, msg) do
          try do
            {_, child_field_value} = msg.action
            [acc, "\x1A", Protox.Encode.encode_message(child_field_value)]
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:player_move, "invalid field value"),
                      __STACKTRACE__
          end
        end
      ]

      defp encode_unknown_fields(acc, msg) do
        Enum.reduce(msg.__struct__.unknown_fields(msg), acc, fn {tag, wire_type, bytes}, acc ->
          case wire_type do
            0 ->
              [acc, Protox.Encode.make_key_bytes(tag, :int32), bytes]

            1 ->
              [acc, Protox.Encode.make_key_bytes(tag, :double), bytes]

            2 ->
              len_bytes = bytes |> byte_size() |> Protox.Varint.encode()
              [acc, Protox.Encode.make_key_bytes(tag, :packed), len_bytes, bytes]

            5 ->
              [acc, Protox.Encode.make_key_bytes(tag, :float), bytes]
          end
        end)
      end
    )

    (
      (
        @spec decode(binary) :: {:ok, struct} | {:error, any}
        def decode(bytes) do
          try do
            {:ok, decode!(bytes)}
          rescue
            e in [Protox.DecodingError, Protox.IllegalTagError, Protox.RequiredFieldsError] ->
              {:error, e}
          end
        end

        (
          @spec decode!(binary) :: struct | no_return
          def decode!(bytes) do
            parse_key_value(bytes, struct(Broadcast.Player.Action))
          end
        )
      )

      (
        @spec parse_key_value(binary, struct) :: struct
        defp parse_key_value(<<>>, msg) do
          msg
        end

        defp parse_key_value(bytes, msg) do
          {field, rest} =
            case Protox.Decode.parse_key(bytes) do
              {0, _, _} ->
                raise %Protox.IllegalTagError{}

              {1, _, bytes} ->
                {len, bytes} = Protox.Varint.decode(bytes)
                {delimited, rest} = Protox.Decode.parse_delimited(bytes, len)

                {[
                   case msg.action do
                     {:player_enter, previous_value} ->
                       {:action,
                        {:player_enter,
                         Protox.MergeMessage.merge(
                           previous_value,
                           Broadcast.Player.PlayerEnter.decode!(delimited)
                         )}}

                     _ ->
                       {:action, {:player_enter, Broadcast.Player.PlayerEnter.decode!(delimited)}}
                   end
                 ], rest}

              {2, _, bytes} ->
                {len, bytes} = Protox.Varint.decode(bytes)
                {delimited, rest} = Protox.Decode.parse_delimited(bytes, len)

                {[
                   case msg.action do
                     {:player_leave, previous_value} ->
                       {:action,
                        {:player_leave,
                         Protox.MergeMessage.merge(
                           previous_value,
                           Broadcast.Player.PlayerLeave.decode!(delimited)
                         )}}

                     _ ->
                       {:action, {:player_leave, Broadcast.Player.PlayerLeave.decode!(delimited)}}
                   end
                 ], rest}

              {3, _, bytes} ->
                {len, bytes} = Protox.Varint.decode(bytes)
                {delimited, rest} = Protox.Decode.parse_delimited(bytes, len)

                {[
                   case msg.action do
                     {:player_move, previous_value} ->
                       {:action,
                        {:player_move,
                         Protox.MergeMessage.merge(
                           previous_value,
                           Broadcast.Player.PlayerMove.decode!(delimited)
                         )}}

                     _ ->
                       {:action, {:player_move, Broadcast.Player.PlayerMove.decode!(delimited)}}
                   end
                 ], rest}

              {tag, wire_type, rest} ->
                {value, rest} = Protox.Decode.parse_unknown(tag, wire_type, rest)

                {[
                   {msg.__struct__.unknown_fields_name,
                    [value | msg.__struct__.unknown_fields(msg)]}
                 ], rest}
            end

          msg_updated = struct(msg, field)
          parse_key_value(rest, msg_updated)
        end
      )

      []
    )

    (
      @spec json_decode(iodata(), keyword()) :: {:ok, struct()} | {:error, any()}
      def json_decode(input, opts \\ []) do
        try do
          {:ok, json_decode!(input, opts)}
        rescue
          e in Protox.JsonDecodingError -> {:error, e}
        end
      end

      @spec json_decode!(iodata(), keyword()) :: struct() | no_return()
      def json_decode!(input, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :decode)

        Protox.JsonDecode.decode!(
          input,
          Broadcast.Player.Action,
          &json_library_wrapper.decode!(json_library, &1)
        )
      end

      @spec json_encode(struct(), keyword()) :: {:ok, iodata()} | {:error, any()}
      def json_encode(msg, opts \\ []) do
        try do
          {:ok, json_encode!(msg, opts)}
        rescue
          e in Protox.JsonEncodingError -> {:error, e}
        end
      end

      @spec json_encode!(struct(), keyword()) :: iodata() | no_return()
      def json_encode!(msg, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :encode)
        Protox.JsonEncode.encode!(msg, &json_library_wrapper.encode!(json_library, &1))
      end
    )

    (
      @deprecated "Use fields_defs()/0 instead"
      @spec defs() :: %{
              required(non_neg_integer) => {atom, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs() do
        %{
          1 => {:player_enter, {:oneof, :action}, {:message, Broadcast.Player.PlayerEnter}},
          2 => {:player_leave, {:oneof, :action}, {:message, Broadcast.Player.PlayerLeave}},
          3 => {:player_move, {:oneof, :action}, {:message, Broadcast.Player.PlayerMove}}
        }
      end

      @deprecated "Use fields_defs()/0 instead"
      @spec defs_by_name() :: %{
              required(atom) => {non_neg_integer, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs_by_name() do
        %{
          player_enter: {1, {:oneof, :action}, {:message, Broadcast.Player.PlayerEnter}},
          player_leave: {2, {:oneof, :action}, {:message, Broadcast.Player.PlayerLeave}},
          player_move: {3, {:oneof, :action}, {:message, Broadcast.Player.PlayerMove}}
        }
      end
    )

    (
      @spec fields_defs() :: list(Protox.Field.t())
      def fields_defs() do
        [
          %{
            __struct__: Protox.Field,
            json_name: "playerEnter",
            kind: {:oneof, :action},
            label: :optional,
            name: :player_enter,
            tag: 1,
            type: {:message, Broadcast.Player.PlayerEnter}
          },
          %{
            __struct__: Protox.Field,
            json_name: "playerLeave",
            kind: {:oneof, :action},
            label: :optional,
            name: :player_leave,
            tag: 2,
            type: {:message, Broadcast.Player.PlayerLeave}
          },
          %{
            __struct__: Protox.Field,
            json_name: "playerMove",
            kind: {:oneof, :action},
            label: :optional,
            name: :player_move,
            tag: 3,
            type: {:message, Broadcast.Player.PlayerMove}
          }
        ]
      end

      [
        @spec(field_def(atom) :: {:ok, Protox.Field.t()} | {:error, :no_such_field}),
        (
          def field_def(:player_enter) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "playerEnter",
               kind: {:oneof, :action},
               label: :optional,
               name: :player_enter,
               tag: 1,
               type: {:message, Broadcast.Player.PlayerEnter}
             }}
          end

          def field_def("playerEnter") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "playerEnter",
               kind: {:oneof, :action},
               label: :optional,
               name: :player_enter,
               tag: 1,
               type: {:message, Broadcast.Player.PlayerEnter}
             }}
          end

          def field_def("player_enter") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "playerEnter",
               kind: {:oneof, :action},
               label: :optional,
               name: :player_enter,
               tag: 1,
               type: {:message, Broadcast.Player.PlayerEnter}
             }}
          end
        ),
        (
          def field_def(:player_leave) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "playerLeave",
               kind: {:oneof, :action},
               label: :optional,
               name: :player_leave,
               tag: 2,
               type: {:message, Broadcast.Player.PlayerLeave}
             }}
          end

          def field_def("playerLeave") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "playerLeave",
               kind: {:oneof, :action},
               label: :optional,
               name: :player_leave,
               tag: 2,
               type: {:message, Broadcast.Player.PlayerLeave}
             }}
          end

          def field_def("player_leave") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "playerLeave",
               kind: {:oneof, :action},
               label: :optional,
               name: :player_leave,
               tag: 2,
               type: {:message, Broadcast.Player.PlayerLeave}
             }}
          end
        ),
        (
          def field_def(:player_move) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "playerMove",
               kind: {:oneof, :action},
               label: :optional,
               name: :player_move,
               tag: 3,
               type: {:message, Broadcast.Player.PlayerMove}
             }}
          end

          def field_def("playerMove") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "playerMove",
               kind: {:oneof, :action},
               label: :optional,
               name: :player_move,
               tag: 3,
               type: {:message, Broadcast.Player.PlayerMove}
             }}
          end

          def field_def("player_move") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "playerMove",
               kind: {:oneof, :action},
               label: :optional,
               name: :player_move,
               tag: 3,
               type: {:message, Broadcast.Player.PlayerMove}
             }}
          end
        ),
        def field_def(_) do
          {:error, :no_such_field}
        end
      ]
    )

    (
      @spec unknown_fields(struct) :: [{non_neg_integer, Protox.Types.tag(), binary}]
      def unknown_fields(msg) do
        msg.__uf__
      end

      @spec unknown_fields_name() :: :__uf__
      def unknown_fields_name() do
        :__uf__
      end

      @spec clear_unknown_fields(struct) :: struct
      def clear_unknown_fields(msg) do
        struct!(msg, [{unknown_fields_name(), []}])
      end
    )

    (
      @spec required_fields() :: []
      def required_fields() do
        []
      end
    )

    (
      @spec syntax() :: atom()
      def syntax() do
        :proto3
      end
    )

    [
      @spec(default(atom) :: {:ok, boolean | integer | String.t() | float} | {:error, atom}),
      def default(:player_enter) do
        {:error, :no_default_value}
      end,
      def default(:player_leave) do
        {:error, :no_default_value}
      end,
      def default(:player_move) do
        {:error, :no_default_value}
      end,
      def default(_) do
        {:error, :no_such_field}
      end
    ]

    (
      @spec file_options() :: nil
      def file_options() do
        nil
      end
    )
  end,
  defmodule Broadcast.Player.PlayerEnter do
    @moduledoc false
    defstruct cid: 0, location: nil, __uf__: []

    (
      (
        @spec encode(struct) :: {:ok, iodata} | {:error, any}
        def encode(msg) do
          try do
            {:ok, encode!(msg)}
          rescue
            e in [Protox.EncodingError, Protox.RequiredFieldsError] -> {:error, e}
          end
        end

        @spec encode!(struct) :: iodata | no_return
        def encode!(msg) do
          [] |> encode_cid(msg) |> encode_location(msg) |> encode_unknown_fields(msg)
        end
      )

      []

      [
        defp encode_cid(acc, msg) do
          try do
            if msg.cid == 0 do
              acc
            else
              [acc, "\b", Protox.Encode.encode_int64(msg.cid)]
            end
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:cid, "invalid field value"), __STACKTRACE__
          end
        end,
        defp encode_location(acc, msg) do
          try do
            if msg.location == nil do
              acc
            else
              [acc, "\x12", Protox.Encode.encode_message(msg.location)]
            end
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:location, "invalid field value"), __STACKTRACE__
          end
        end
      ]

      defp encode_unknown_fields(acc, msg) do
        Enum.reduce(msg.__struct__.unknown_fields(msg), acc, fn {tag, wire_type, bytes}, acc ->
          case wire_type do
            0 ->
              [acc, Protox.Encode.make_key_bytes(tag, :int32), bytes]

            1 ->
              [acc, Protox.Encode.make_key_bytes(tag, :double), bytes]

            2 ->
              len_bytes = bytes |> byte_size() |> Protox.Varint.encode()
              [acc, Protox.Encode.make_key_bytes(tag, :packed), len_bytes, bytes]

            5 ->
              [acc, Protox.Encode.make_key_bytes(tag, :float), bytes]
          end
        end)
      end
    )

    (
      (
        @spec decode(binary) :: {:ok, struct} | {:error, any}
        def decode(bytes) do
          try do
            {:ok, decode!(bytes)}
          rescue
            e in [Protox.DecodingError, Protox.IllegalTagError, Protox.RequiredFieldsError] ->
              {:error, e}
          end
        end

        (
          @spec decode!(binary) :: struct | no_return
          def decode!(bytes) do
            parse_key_value(bytes, struct(Broadcast.Player.PlayerEnter))
          end
        )
      )

      (
        @spec parse_key_value(binary, struct) :: struct
        defp parse_key_value(<<>>, msg) do
          msg
        end

        defp parse_key_value(bytes, msg) do
          {field, rest} =
            case Protox.Decode.parse_key(bytes) do
              {0, _, _} ->
                raise %Protox.IllegalTagError{}

              {1, _, bytes} ->
                {value, rest} = Protox.Decode.parse_int64(bytes)
                {[cid: value], rest}

              {2, _, bytes} ->
                {len, bytes} = Protox.Varint.decode(bytes)
                {delimited, rest} = Protox.Decode.parse_delimited(bytes, len)

                {[
                   location:
                     Protox.MergeMessage.merge(msg.location, Types.Vector.decode!(delimited))
                 ], rest}

              {tag, wire_type, rest} ->
                {value, rest} = Protox.Decode.parse_unknown(tag, wire_type, rest)

                {[
                   {msg.__struct__.unknown_fields_name,
                    [value | msg.__struct__.unknown_fields(msg)]}
                 ], rest}
            end

          msg_updated = struct(msg, field)
          parse_key_value(rest, msg_updated)
        end
      )

      []
    )

    (
      @spec json_decode(iodata(), keyword()) :: {:ok, struct()} | {:error, any()}
      def json_decode(input, opts \\ []) do
        try do
          {:ok, json_decode!(input, opts)}
        rescue
          e in Protox.JsonDecodingError -> {:error, e}
        end
      end

      @spec json_decode!(iodata(), keyword()) :: struct() | no_return()
      def json_decode!(input, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :decode)

        Protox.JsonDecode.decode!(
          input,
          Broadcast.Player.PlayerEnter,
          &json_library_wrapper.decode!(json_library, &1)
        )
      end

      @spec json_encode(struct(), keyword()) :: {:ok, iodata()} | {:error, any()}
      def json_encode(msg, opts \\ []) do
        try do
          {:ok, json_encode!(msg, opts)}
        rescue
          e in Protox.JsonEncodingError -> {:error, e}
        end
      end

      @spec json_encode!(struct(), keyword()) :: iodata() | no_return()
      def json_encode!(msg, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :encode)
        Protox.JsonEncode.encode!(msg, &json_library_wrapper.encode!(json_library, &1))
      end
    )

    (
      @deprecated "Use fields_defs()/0 instead"
      @spec defs() :: %{
              required(non_neg_integer) => {atom, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs() do
        %{
          1 => {:cid, {:scalar, 0}, :int64},
          2 => {:location, {:scalar, nil}, {:message, Types.Vector}}
        }
      end

      @deprecated "Use fields_defs()/0 instead"
      @spec defs_by_name() :: %{
              required(atom) => {non_neg_integer, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs_by_name() do
        %{cid: {1, {:scalar, 0}, :int64}, location: {2, {:scalar, nil}, {:message, Types.Vector}}}
      end
    )

    (
      @spec fields_defs() :: list(Protox.Field.t())
      def fields_defs() do
        [
          %{
            __struct__: Protox.Field,
            json_name: "cid",
            kind: {:scalar, 0},
            label: :optional,
            name: :cid,
            tag: 1,
            type: :int64
          },
          %{
            __struct__: Protox.Field,
            json_name: "location",
            kind: {:scalar, nil},
            label: :optional,
            name: :location,
            tag: 2,
            type: {:message, Types.Vector}
          }
        ]
      end

      [
        @spec(field_def(atom) :: {:ok, Protox.Field.t()} | {:error, :no_such_field}),
        (
          def field_def(:cid) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "cid",
               kind: {:scalar, 0},
               label: :optional,
               name: :cid,
               tag: 1,
               type: :int64
             }}
          end

          def field_def("cid") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "cid",
               kind: {:scalar, 0},
               label: :optional,
               name: :cid,
               tag: 1,
               type: :int64
             }}
          end

          []
        ),
        (
          def field_def(:location) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "location",
               kind: {:scalar, nil},
               label: :optional,
               name: :location,
               tag: 2,
               type: {:message, Types.Vector}
             }}
          end

          def field_def("location") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "location",
               kind: {:scalar, nil},
               label: :optional,
               name: :location,
               tag: 2,
               type: {:message, Types.Vector}
             }}
          end

          []
        ),
        def field_def(_) do
          {:error, :no_such_field}
        end
      ]
    )

    (
      @spec unknown_fields(struct) :: [{non_neg_integer, Protox.Types.tag(), binary}]
      def unknown_fields(msg) do
        msg.__uf__
      end

      @spec unknown_fields_name() :: :__uf__
      def unknown_fields_name() do
        :__uf__
      end

      @spec clear_unknown_fields(struct) :: struct
      def clear_unknown_fields(msg) do
        struct!(msg, [{unknown_fields_name(), []}])
      end
    )

    (
      @spec required_fields() :: []
      def required_fields() do
        []
      end
    )

    (
      @spec syntax() :: atom()
      def syntax() do
        :proto3
      end
    )

    [
      @spec(default(atom) :: {:ok, boolean | integer | String.t() | float} | {:error, atom}),
      def default(:cid) do
        {:ok, 0}
      end,
      def default(:location) do
        {:ok, nil}
      end,
      def default(_) do
        {:error, :no_such_field}
      end
    ]

    (
      @spec file_options() :: nil
      def file_options() do
        nil
      end
    )
  end,
  defmodule Broadcast.Player.PlayerJump do
    @moduledoc false
    defstruct cid: 0, movement: nil, __uf__: []

    (
      (
        @spec encode(struct) :: {:ok, iodata} | {:error, any}
        def encode(msg) do
          try do
            {:ok, encode!(msg)}
          rescue
            e in [Protox.EncodingError, Protox.RequiredFieldsError] -> {:error, e}
          end
        end

        @spec encode!(struct) :: iodata | no_return
        def encode!(msg) do
          [] |> encode_cid(msg) |> encode_movement(msg) |> encode_unknown_fields(msg)
        end
      )

      []

      [
        defp encode_cid(acc, msg) do
          try do
            if msg.cid == 0 do
              acc
            else
              [acc, "\b", Protox.Encode.encode_int64(msg.cid)]
            end
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:cid, "invalid field value"), __STACKTRACE__
          end
        end,
        defp encode_movement(acc, msg) do
          try do
            if msg.movement == nil do
              acc
            else
              [acc, "\x12", Protox.Encode.encode_message(msg.movement)]
            end
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:movement, "invalid field value"), __STACKTRACE__
          end
        end
      ]

      defp encode_unknown_fields(acc, msg) do
        Enum.reduce(msg.__struct__.unknown_fields(msg), acc, fn {tag, wire_type, bytes}, acc ->
          case wire_type do
            0 ->
              [acc, Protox.Encode.make_key_bytes(tag, :int32), bytes]

            1 ->
              [acc, Protox.Encode.make_key_bytes(tag, :double), bytes]

            2 ->
              len_bytes = bytes |> byte_size() |> Protox.Varint.encode()
              [acc, Protox.Encode.make_key_bytes(tag, :packed), len_bytes, bytes]

            5 ->
              [acc, Protox.Encode.make_key_bytes(tag, :float), bytes]
          end
        end)
      end
    )

    (
      (
        @spec decode(binary) :: {:ok, struct} | {:error, any}
        def decode(bytes) do
          try do
            {:ok, decode!(bytes)}
          rescue
            e in [Protox.DecodingError, Protox.IllegalTagError, Protox.RequiredFieldsError] ->
              {:error, e}
          end
        end

        (
          @spec decode!(binary) :: struct | no_return
          def decode!(bytes) do
            parse_key_value(bytes, struct(Broadcast.Player.PlayerJump))
          end
        )
      )

      (
        @spec parse_key_value(binary, struct) :: struct
        defp parse_key_value(<<>>, msg) do
          msg
        end

        defp parse_key_value(bytes, msg) do
          {field, rest} =
            case Protox.Decode.parse_key(bytes) do
              {0, _, _} ->
                raise %Protox.IllegalTagError{}

              {1, _, bytes} ->
                {value, rest} = Protox.Decode.parse_int64(bytes)
                {[cid: value], rest}

              {2, _, bytes} ->
                {len, bytes} = Protox.Varint.decode(bytes)
                {delimited, rest} = Protox.Decode.parse_delimited(bytes, len)

                {[
                   movement:
                     Protox.MergeMessage.merge(msg.movement, Types.Movement.decode!(delimited))
                 ], rest}

              {tag, wire_type, rest} ->
                {value, rest} = Protox.Decode.parse_unknown(tag, wire_type, rest)

                {[
                   {msg.__struct__.unknown_fields_name,
                    [value | msg.__struct__.unknown_fields(msg)]}
                 ], rest}
            end

          msg_updated = struct(msg, field)
          parse_key_value(rest, msg_updated)
        end
      )

      []
    )

    (
      @spec json_decode(iodata(), keyword()) :: {:ok, struct()} | {:error, any()}
      def json_decode(input, opts \\ []) do
        try do
          {:ok, json_decode!(input, opts)}
        rescue
          e in Protox.JsonDecodingError -> {:error, e}
        end
      end

      @spec json_decode!(iodata(), keyword()) :: struct() | no_return()
      def json_decode!(input, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :decode)

        Protox.JsonDecode.decode!(
          input,
          Broadcast.Player.PlayerJump,
          &json_library_wrapper.decode!(json_library, &1)
        )
      end

      @spec json_encode(struct(), keyword()) :: {:ok, iodata()} | {:error, any()}
      def json_encode(msg, opts \\ []) do
        try do
          {:ok, json_encode!(msg, opts)}
        rescue
          e in Protox.JsonEncodingError -> {:error, e}
        end
      end

      @spec json_encode!(struct(), keyword()) :: iodata() | no_return()
      def json_encode!(msg, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :encode)
        Protox.JsonEncode.encode!(msg, &json_library_wrapper.encode!(json_library, &1))
      end
    )

    (
      @deprecated "Use fields_defs()/0 instead"
      @spec defs() :: %{
              required(non_neg_integer) => {atom, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs() do
        %{
          1 => {:cid, {:scalar, 0}, :int64},
          2 => {:movement, {:scalar, nil}, {:message, Types.Movement}}
        }
      end

      @deprecated "Use fields_defs()/0 instead"
      @spec defs_by_name() :: %{
              required(atom) => {non_neg_integer, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs_by_name() do
        %{
          cid: {1, {:scalar, 0}, :int64},
          movement: {2, {:scalar, nil}, {:message, Types.Movement}}
        }
      end
    )

    (
      @spec fields_defs() :: list(Protox.Field.t())
      def fields_defs() do
        [
          %{
            __struct__: Protox.Field,
            json_name: "cid",
            kind: {:scalar, 0},
            label: :optional,
            name: :cid,
            tag: 1,
            type: :int64
          },
          %{
            __struct__: Protox.Field,
            json_name: "movement",
            kind: {:scalar, nil},
            label: :optional,
            name: :movement,
            tag: 2,
            type: {:message, Types.Movement}
          }
        ]
      end

      [
        @spec(field_def(atom) :: {:ok, Protox.Field.t()} | {:error, :no_such_field}),
        (
          def field_def(:cid) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "cid",
               kind: {:scalar, 0},
               label: :optional,
               name: :cid,
               tag: 1,
               type: :int64
             }}
          end

          def field_def("cid") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "cid",
               kind: {:scalar, 0},
               label: :optional,
               name: :cid,
               tag: 1,
               type: :int64
             }}
          end

          []
        ),
        (
          def field_def(:movement) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "movement",
               kind: {:scalar, nil},
               label: :optional,
               name: :movement,
               tag: 2,
               type: {:message, Types.Movement}
             }}
          end

          def field_def("movement") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "movement",
               kind: {:scalar, nil},
               label: :optional,
               name: :movement,
               tag: 2,
               type: {:message, Types.Movement}
             }}
          end

          []
        ),
        def field_def(_) do
          {:error, :no_such_field}
        end
      ]
    )

    (
      @spec unknown_fields(struct) :: [{non_neg_integer, Protox.Types.tag(), binary}]
      def unknown_fields(msg) do
        msg.__uf__
      end

      @spec unknown_fields_name() :: :__uf__
      def unknown_fields_name() do
        :__uf__
      end

      @spec clear_unknown_fields(struct) :: struct
      def clear_unknown_fields(msg) do
        struct!(msg, [{unknown_fields_name(), []}])
      end
    )

    (
      @spec required_fields() :: []
      def required_fields() do
        []
      end
    )

    (
      @spec syntax() :: atom()
      def syntax() do
        :proto3
      end
    )

    [
      @spec(default(atom) :: {:ok, boolean | integer | String.t() | float} | {:error, atom}),
      def default(:cid) do
        {:ok, 0}
      end,
      def default(:movement) do
        {:ok, nil}
      end,
      def default(_) do
        {:error, :no_such_field}
      end
    ]

    (
      @spec file_options() :: nil
      def file_options() do
        nil
      end
    )
  end,
  defmodule Broadcast.Player.PlayerLeave do
    @moduledoc false
    defstruct cid: 0, __uf__: []

    (
      (
        @spec encode(struct) :: {:ok, iodata} | {:error, any}
        def encode(msg) do
          try do
            {:ok, encode!(msg)}
          rescue
            e in [Protox.EncodingError, Protox.RequiredFieldsError] -> {:error, e}
          end
        end

        @spec encode!(struct) :: iodata | no_return
        def encode!(msg) do
          [] |> encode_cid(msg) |> encode_unknown_fields(msg)
        end
      )

      []

      [
        defp encode_cid(acc, msg) do
          try do
            if msg.cid == 0 do
              acc
            else
              [acc, "\b", Protox.Encode.encode_int64(msg.cid)]
            end
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:cid, "invalid field value"), __STACKTRACE__
          end
        end
      ]

      defp encode_unknown_fields(acc, msg) do
        Enum.reduce(msg.__struct__.unknown_fields(msg), acc, fn {tag, wire_type, bytes}, acc ->
          case wire_type do
            0 ->
              [acc, Protox.Encode.make_key_bytes(tag, :int32), bytes]

            1 ->
              [acc, Protox.Encode.make_key_bytes(tag, :double), bytes]

            2 ->
              len_bytes = bytes |> byte_size() |> Protox.Varint.encode()
              [acc, Protox.Encode.make_key_bytes(tag, :packed), len_bytes, bytes]

            5 ->
              [acc, Protox.Encode.make_key_bytes(tag, :float), bytes]
          end
        end)
      end
    )

    (
      (
        @spec decode(binary) :: {:ok, struct} | {:error, any}
        def decode(bytes) do
          try do
            {:ok, decode!(bytes)}
          rescue
            e in [Protox.DecodingError, Protox.IllegalTagError, Protox.RequiredFieldsError] ->
              {:error, e}
          end
        end

        (
          @spec decode!(binary) :: struct | no_return
          def decode!(bytes) do
            parse_key_value(bytes, struct(Broadcast.Player.PlayerLeave))
          end
        )
      )

      (
        @spec parse_key_value(binary, struct) :: struct
        defp parse_key_value(<<>>, msg) do
          msg
        end

        defp parse_key_value(bytes, msg) do
          {field, rest} =
            case Protox.Decode.parse_key(bytes) do
              {0, _, _} ->
                raise %Protox.IllegalTagError{}

              {1, _, bytes} ->
                {value, rest} = Protox.Decode.parse_int64(bytes)
                {[cid: value], rest}

              {tag, wire_type, rest} ->
                {value, rest} = Protox.Decode.parse_unknown(tag, wire_type, rest)

                {[
                   {msg.__struct__.unknown_fields_name,
                    [value | msg.__struct__.unknown_fields(msg)]}
                 ], rest}
            end

          msg_updated = struct(msg, field)
          parse_key_value(rest, msg_updated)
        end
      )

      []
    )

    (
      @spec json_decode(iodata(), keyword()) :: {:ok, struct()} | {:error, any()}
      def json_decode(input, opts \\ []) do
        try do
          {:ok, json_decode!(input, opts)}
        rescue
          e in Protox.JsonDecodingError -> {:error, e}
        end
      end

      @spec json_decode!(iodata(), keyword()) :: struct() | no_return()
      def json_decode!(input, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :decode)

        Protox.JsonDecode.decode!(
          input,
          Broadcast.Player.PlayerLeave,
          &json_library_wrapper.decode!(json_library, &1)
        )
      end

      @spec json_encode(struct(), keyword()) :: {:ok, iodata()} | {:error, any()}
      def json_encode(msg, opts \\ []) do
        try do
          {:ok, json_encode!(msg, opts)}
        rescue
          e in Protox.JsonEncodingError -> {:error, e}
        end
      end

      @spec json_encode!(struct(), keyword()) :: iodata() | no_return()
      def json_encode!(msg, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :encode)
        Protox.JsonEncode.encode!(msg, &json_library_wrapper.encode!(json_library, &1))
      end
    )

    (
      @deprecated "Use fields_defs()/0 instead"
      @spec defs() :: %{
              required(non_neg_integer) => {atom, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs() do
        %{1 => {:cid, {:scalar, 0}, :int64}}
      end

      @deprecated "Use fields_defs()/0 instead"
      @spec defs_by_name() :: %{
              required(atom) => {non_neg_integer, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs_by_name() do
        %{cid: {1, {:scalar, 0}, :int64}}
      end
    )

    (
      @spec fields_defs() :: list(Protox.Field.t())
      def fields_defs() do
        [
          %{
            __struct__: Protox.Field,
            json_name: "cid",
            kind: {:scalar, 0},
            label: :optional,
            name: :cid,
            tag: 1,
            type: :int64
          }
        ]
      end

      [
        @spec(field_def(atom) :: {:ok, Protox.Field.t()} | {:error, :no_such_field}),
        (
          def field_def(:cid) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "cid",
               kind: {:scalar, 0},
               label: :optional,
               name: :cid,
               tag: 1,
               type: :int64
             }}
          end

          def field_def("cid") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "cid",
               kind: {:scalar, 0},
               label: :optional,
               name: :cid,
               tag: 1,
               type: :int64
             }}
          end

          []
        ),
        def field_def(_) do
          {:error, :no_such_field}
        end
      ]
    )

    (
      @spec unknown_fields(struct) :: [{non_neg_integer, Protox.Types.tag(), binary}]
      def unknown_fields(msg) do
        msg.__uf__
      end

      @spec unknown_fields_name() :: :__uf__
      def unknown_fields_name() do
        :__uf__
      end

      @spec clear_unknown_fields(struct) :: struct
      def clear_unknown_fields(msg) do
        struct!(msg, [{unknown_fields_name(), []}])
      end
    )

    (
      @spec required_fields() :: []
      def required_fields() do
        []
      end
    )

    (
      @spec syntax() :: atom()
      def syntax() do
        :proto3
      end
    )

    [
      @spec(default(atom) :: {:ok, boolean | integer | String.t() | float} | {:error, atom}),
      def default(:cid) do
        {:ok, 0}
      end,
      def default(_) do
        {:error, :no_such_field}
      end
    ]

    (
      @spec file_options() :: nil
      def file_options() do
        nil
      end
    )
  end,
  defmodule Broadcast.Player.PlayerMove do
    @moduledoc false
    defstruct cid: 0, movement: nil, __uf__: []

    (
      (
        @spec encode(struct) :: {:ok, iodata} | {:error, any}
        def encode(msg) do
          try do
            {:ok, encode!(msg)}
          rescue
            e in [Protox.EncodingError, Protox.RequiredFieldsError] -> {:error, e}
          end
        end

        @spec encode!(struct) :: iodata | no_return
        def encode!(msg) do
          [] |> encode_cid(msg) |> encode_movement(msg) |> encode_unknown_fields(msg)
        end
      )

      []

      [
        defp encode_cid(acc, msg) do
          try do
            if msg.cid == 0 do
              acc
            else
              [acc, "\b", Protox.Encode.encode_int64(msg.cid)]
            end
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:cid, "invalid field value"), __STACKTRACE__
          end
        end,
        defp encode_movement(acc, msg) do
          try do
            if msg.movement == nil do
              acc
            else
              [acc, "\x12", Protox.Encode.encode_message(msg.movement)]
            end
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:movement, "invalid field value"), __STACKTRACE__
          end
        end
      ]

      defp encode_unknown_fields(acc, msg) do
        Enum.reduce(msg.__struct__.unknown_fields(msg), acc, fn {tag, wire_type, bytes}, acc ->
          case wire_type do
            0 ->
              [acc, Protox.Encode.make_key_bytes(tag, :int32), bytes]

            1 ->
              [acc, Protox.Encode.make_key_bytes(tag, :double), bytes]

            2 ->
              len_bytes = bytes |> byte_size() |> Protox.Varint.encode()
              [acc, Protox.Encode.make_key_bytes(tag, :packed), len_bytes, bytes]

            5 ->
              [acc, Protox.Encode.make_key_bytes(tag, :float), bytes]
          end
        end)
      end
    )

    (
      (
        @spec decode(binary) :: {:ok, struct} | {:error, any}
        def decode(bytes) do
          try do
            {:ok, decode!(bytes)}
          rescue
            e in [Protox.DecodingError, Protox.IllegalTagError, Protox.RequiredFieldsError] ->
              {:error, e}
          end
        end

        (
          @spec decode!(binary) :: struct | no_return
          def decode!(bytes) do
            parse_key_value(bytes, struct(Broadcast.Player.PlayerMove))
          end
        )
      )

      (
        @spec parse_key_value(binary, struct) :: struct
        defp parse_key_value(<<>>, msg) do
          msg
        end

        defp parse_key_value(bytes, msg) do
          {field, rest} =
            case Protox.Decode.parse_key(bytes) do
              {0, _, _} ->
                raise %Protox.IllegalTagError{}

              {1, _, bytes} ->
                {value, rest} = Protox.Decode.parse_int64(bytes)
                {[cid: value], rest}

              {2, _, bytes} ->
                {len, bytes} = Protox.Varint.decode(bytes)
                {delimited, rest} = Protox.Decode.parse_delimited(bytes, len)

                {[
                   movement:
                     Protox.MergeMessage.merge(msg.movement, Types.Movement.decode!(delimited))
                 ], rest}

              {tag, wire_type, rest} ->
                {value, rest} = Protox.Decode.parse_unknown(tag, wire_type, rest)

                {[
                   {msg.__struct__.unknown_fields_name,
                    [value | msg.__struct__.unknown_fields(msg)]}
                 ], rest}
            end

          msg_updated = struct(msg, field)
          parse_key_value(rest, msg_updated)
        end
      )

      []
    )

    (
      @spec json_decode(iodata(), keyword()) :: {:ok, struct()} | {:error, any()}
      def json_decode(input, opts \\ []) do
        try do
          {:ok, json_decode!(input, opts)}
        rescue
          e in Protox.JsonDecodingError -> {:error, e}
        end
      end

      @spec json_decode!(iodata(), keyword()) :: struct() | no_return()
      def json_decode!(input, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :decode)

        Protox.JsonDecode.decode!(
          input,
          Broadcast.Player.PlayerMove,
          &json_library_wrapper.decode!(json_library, &1)
        )
      end

      @spec json_encode(struct(), keyword()) :: {:ok, iodata()} | {:error, any()}
      def json_encode(msg, opts \\ []) do
        try do
          {:ok, json_encode!(msg, opts)}
        rescue
          e in Protox.JsonEncodingError -> {:error, e}
        end
      end

      @spec json_encode!(struct(), keyword()) :: iodata() | no_return()
      def json_encode!(msg, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :encode)
        Protox.JsonEncode.encode!(msg, &json_library_wrapper.encode!(json_library, &1))
      end
    )

    (
      @deprecated "Use fields_defs()/0 instead"
      @spec defs() :: %{
              required(non_neg_integer) => {atom, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs() do
        %{
          1 => {:cid, {:scalar, 0}, :int64},
          2 => {:movement, {:scalar, nil}, {:message, Types.Movement}}
        }
      end

      @deprecated "Use fields_defs()/0 instead"
      @spec defs_by_name() :: %{
              required(atom) => {non_neg_integer, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs_by_name() do
        %{
          cid: {1, {:scalar, 0}, :int64},
          movement: {2, {:scalar, nil}, {:message, Types.Movement}}
        }
      end
    )

    (
      @spec fields_defs() :: list(Protox.Field.t())
      def fields_defs() do
        [
          %{
            __struct__: Protox.Field,
            json_name: "cid",
            kind: {:scalar, 0},
            label: :optional,
            name: :cid,
            tag: 1,
            type: :int64
          },
          %{
            __struct__: Protox.Field,
            json_name: "movement",
            kind: {:scalar, nil},
            label: :optional,
            name: :movement,
            tag: 2,
            type: {:message, Types.Movement}
          }
        ]
      end

      [
        @spec(field_def(atom) :: {:ok, Protox.Field.t()} | {:error, :no_such_field}),
        (
          def field_def(:cid) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "cid",
               kind: {:scalar, 0},
               label: :optional,
               name: :cid,
               tag: 1,
               type: :int64
             }}
          end

          def field_def("cid") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "cid",
               kind: {:scalar, 0},
               label: :optional,
               name: :cid,
               tag: 1,
               type: :int64
             }}
          end

          []
        ),
        (
          def field_def(:movement) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "movement",
               kind: {:scalar, nil},
               label: :optional,
               name: :movement,
               tag: 2,
               type: {:message, Types.Movement}
             }}
          end

          def field_def("movement") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "movement",
               kind: {:scalar, nil},
               label: :optional,
               name: :movement,
               tag: 2,
               type: {:message, Types.Movement}
             }}
          end

          []
        ),
        def field_def(_) do
          {:error, :no_such_field}
        end
      ]
    )

    (
      @spec unknown_fields(struct) :: [{non_neg_integer, Protox.Types.tag(), binary}]
      def unknown_fields(msg) do
        msg.__uf__
      end

      @spec unknown_fields_name() :: :__uf__
      def unknown_fields_name() do
        :__uf__
      end

      @spec clear_unknown_fields(struct) :: struct
      def clear_unknown_fields(msg) do
        struct!(msg, [{unknown_fields_name(), []}])
      end
    )

    (
      @spec required_fields() :: []
      def required_fields() do
        []
      end
    )

    (
      @spec syntax() :: atom()
      def syntax() do
        :proto3
      end
    )

    [
      @spec(default(atom) :: {:ok, boolean | integer | String.t() | float} | {:error, atom}),
      def default(:cid) do
        {:ok, 0}
      end,
      def default(:movement) do
        {:ok, nil}
      end,
      def default(_) do
        {:error, :no_such_field}
      end
    ]

    (
      @spec file_options() :: nil
      def file_options() do
        nil
      end
    )
  end,
  defmodule Entity.EnterScene do
    @moduledoc false
    defstruct cid: 0, __uf__: []

    (
      (
        @spec encode(struct) :: {:ok, iodata} | {:error, any}
        def encode(msg) do
          try do
            {:ok, encode!(msg)}
          rescue
            e in [Protox.EncodingError, Protox.RequiredFieldsError] -> {:error, e}
          end
        end

        @spec encode!(struct) :: iodata | no_return
        def encode!(msg) do
          [] |> encode_cid(msg) |> encode_unknown_fields(msg)
        end
      )

      []

      [
        defp encode_cid(acc, msg) do
          try do
            if msg.cid == 0 do
              acc
            else
              [acc, "\b", Protox.Encode.encode_int64(msg.cid)]
            end
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:cid, "invalid field value"), __STACKTRACE__
          end
        end
      ]

      defp encode_unknown_fields(acc, msg) do
        Enum.reduce(msg.__struct__.unknown_fields(msg), acc, fn {tag, wire_type, bytes}, acc ->
          case wire_type do
            0 ->
              [acc, Protox.Encode.make_key_bytes(tag, :int32), bytes]

            1 ->
              [acc, Protox.Encode.make_key_bytes(tag, :double), bytes]

            2 ->
              len_bytes = bytes |> byte_size() |> Protox.Varint.encode()
              [acc, Protox.Encode.make_key_bytes(tag, :packed), len_bytes, bytes]

            5 ->
              [acc, Protox.Encode.make_key_bytes(tag, :float), bytes]
          end
        end)
      end
    )

    (
      (
        @spec decode(binary) :: {:ok, struct} | {:error, any}
        def decode(bytes) do
          try do
            {:ok, decode!(bytes)}
          rescue
            e in [Protox.DecodingError, Protox.IllegalTagError, Protox.RequiredFieldsError] ->
              {:error, e}
          end
        end

        (
          @spec decode!(binary) :: struct | no_return
          def decode!(bytes) do
            parse_key_value(bytes, struct(Entity.EnterScene))
          end
        )
      )

      (
        @spec parse_key_value(binary, struct) :: struct
        defp parse_key_value(<<>>, msg) do
          msg
        end

        defp parse_key_value(bytes, msg) do
          {field, rest} =
            case Protox.Decode.parse_key(bytes) do
              {0, _, _} ->
                raise %Protox.IllegalTagError{}

              {1, _, bytes} ->
                {value, rest} = Protox.Decode.parse_int64(bytes)
                {[cid: value], rest}

              {tag, wire_type, rest} ->
                {value, rest} = Protox.Decode.parse_unknown(tag, wire_type, rest)

                {[
                   {msg.__struct__.unknown_fields_name,
                    [value | msg.__struct__.unknown_fields(msg)]}
                 ], rest}
            end

          msg_updated = struct(msg, field)
          parse_key_value(rest, msg_updated)
        end
      )

      []
    )

    (
      @spec json_decode(iodata(), keyword()) :: {:ok, struct()} | {:error, any()}
      def json_decode(input, opts \\ []) do
        try do
          {:ok, json_decode!(input, opts)}
        rescue
          e in Protox.JsonDecodingError -> {:error, e}
        end
      end

      @spec json_decode!(iodata(), keyword()) :: struct() | no_return()
      def json_decode!(input, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :decode)

        Protox.JsonDecode.decode!(
          input,
          Entity.EnterScene,
          &json_library_wrapper.decode!(json_library, &1)
        )
      end

      @spec json_encode(struct(), keyword()) :: {:ok, iodata()} | {:error, any()}
      def json_encode(msg, opts \\ []) do
        try do
          {:ok, json_encode!(msg, opts)}
        rescue
          e in Protox.JsonEncodingError -> {:error, e}
        end
      end

      @spec json_encode!(struct(), keyword()) :: iodata() | no_return()
      def json_encode!(msg, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :encode)
        Protox.JsonEncode.encode!(msg, &json_library_wrapper.encode!(json_library, &1))
      end
    )

    (
      @deprecated "Use fields_defs()/0 instead"
      @spec defs() :: %{
              required(non_neg_integer) => {atom, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs() do
        %{1 => {:cid, {:scalar, 0}, :int64}}
      end

      @deprecated "Use fields_defs()/0 instead"
      @spec defs_by_name() :: %{
              required(atom) => {non_neg_integer, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs_by_name() do
        %{cid: {1, {:scalar, 0}, :int64}}
      end
    )

    (
      @spec fields_defs() :: list(Protox.Field.t())
      def fields_defs() do
        [
          %{
            __struct__: Protox.Field,
            json_name: "cid",
            kind: {:scalar, 0},
            label: :optional,
            name: :cid,
            tag: 1,
            type: :int64
          }
        ]
      end

      [
        @spec(field_def(atom) :: {:ok, Protox.Field.t()} | {:error, :no_such_field}),
        (
          def field_def(:cid) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "cid",
               kind: {:scalar, 0},
               label: :optional,
               name: :cid,
               tag: 1,
               type: :int64
             }}
          end

          def field_def("cid") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "cid",
               kind: {:scalar, 0},
               label: :optional,
               name: :cid,
               tag: 1,
               type: :int64
             }}
          end

          []
        ),
        def field_def(_) do
          {:error, :no_such_field}
        end
      ]
    )

    (
      @spec unknown_fields(struct) :: [{non_neg_integer, Protox.Types.tag(), binary}]
      def unknown_fields(msg) do
        msg.__uf__
      end

      @spec unknown_fields_name() :: :__uf__
      def unknown_fields_name() do
        :__uf__
      end

      @spec clear_unknown_fields(struct) :: struct
      def clear_unknown_fields(msg) do
        struct!(msg, [{unknown_fields_name(), []}])
      end
    )

    (
      @spec required_fields() :: []
      def required_fields() do
        []
      end
    )

    (
      @spec syntax() :: atom()
      def syntax() do
        :proto3
      end
    )

    [
      @spec(default(atom) :: {:ok, boolean | integer | String.t() | float} | {:error, atom}),
      def default(:cid) do
        {:ok, 0}
      end,
      def default(_) do
        {:error, :no_such_field}
      end
    ]

    (
      @spec file_options() :: nil
      def file_options() do
        nil
      end
    )
  end,
  defmodule Entity.EntityAction do
    @moduledoc false
    defstruct action: nil, __uf__: []

    (
      (
        @spec encode(struct) :: {:ok, iodata} | {:error, any}
        def encode(msg) do
          try do
            {:ok, encode!(msg)}
          rescue
            e in [Protox.EncodingError, Protox.RequiredFieldsError] -> {:error, e}
          end
        end

        @spec encode!(struct) :: iodata | no_return
        def encode!(msg) do
          [] |> encode_action(msg) |> encode_unknown_fields(msg)
        end
      )

      [
        defp encode_action(acc, msg) do
          case msg.action do
            nil -> acc
            {:enter_scene, _field_value} -> encode_enter_scene(acc, msg)
            {:movement, _field_value} -> encode_movement(acc, msg)
          end
        end
      ]

      [
        defp encode_enter_scene(acc, msg) do
          try do
            {_, child_field_value} = msg.action
            [acc, "\n", Protox.Encode.encode_message(child_field_value)]
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:enter_scene, "invalid field value"),
                      __STACKTRACE__
          end
        end,
        defp encode_movement(acc, msg) do
          try do
            {_, child_field_value} = msg.action
            [acc, "\x12", Protox.Encode.encode_message(child_field_value)]
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:movement, "invalid field value"), __STACKTRACE__
          end
        end
      ]

      defp encode_unknown_fields(acc, msg) do
        Enum.reduce(msg.__struct__.unknown_fields(msg), acc, fn {tag, wire_type, bytes}, acc ->
          case wire_type do
            0 ->
              [acc, Protox.Encode.make_key_bytes(tag, :int32), bytes]

            1 ->
              [acc, Protox.Encode.make_key_bytes(tag, :double), bytes]

            2 ->
              len_bytes = bytes |> byte_size() |> Protox.Varint.encode()
              [acc, Protox.Encode.make_key_bytes(tag, :packed), len_bytes, bytes]

            5 ->
              [acc, Protox.Encode.make_key_bytes(tag, :float), bytes]
          end
        end)
      end
    )

    (
      (
        @spec decode(binary) :: {:ok, struct} | {:error, any}
        def decode(bytes) do
          try do
            {:ok, decode!(bytes)}
          rescue
            e in [Protox.DecodingError, Protox.IllegalTagError, Protox.RequiredFieldsError] ->
              {:error, e}
          end
        end

        (
          @spec decode!(binary) :: struct | no_return
          def decode!(bytes) do
            parse_key_value(bytes, struct(Entity.EntityAction))
          end
        )
      )

      (
        @spec parse_key_value(binary, struct) :: struct
        defp parse_key_value(<<>>, msg) do
          msg
        end

        defp parse_key_value(bytes, msg) do
          {field, rest} =
            case Protox.Decode.parse_key(bytes) do
              {0, _, _} ->
                raise %Protox.IllegalTagError{}

              {1, _, bytes} ->
                {len, bytes} = Protox.Varint.decode(bytes)
                {delimited, rest} = Protox.Decode.parse_delimited(bytes, len)

                {[
                   case msg.action do
                     {:enter_scene, previous_value} ->
                       {:action,
                        {:enter_scene,
                         Protox.MergeMessage.merge(
                           previous_value,
                           Entity.EnterScene.decode!(delimited)
                         )}}

                     _ ->
                       {:action, {:enter_scene, Entity.EnterScene.decode!(delimited)}}
                   end
                 ], rest}

              {2, _, bytes} ->
                {len, bytes} = Protox.Varint.decode(bytes)
                {delimited, rest} = Protox.Decode.parse_delimited(bytes, len)

                {[
                   case msg.action do
                     {:movement, previous_value} ->
                       {:action,
                        {:movement,
                         Protox.MergeMessage.merge(
                           previous_value,
                           Types.Movement.decode!(delimited)
                         )}}

                     _ ->
                       {:action, {:movement, Types.Movement.decode!(delimited)}}
                   end
                 ], rest}

              {tag, wire_type, rest} ->
                {value, rest} = Protox.Decode.parse_unknown(tag, wire_type, rest)

                {[
                   {msg.__struct__.unknown_fields_name,
                    [value | msg.__struct__.unknown_fields(msg)]}
                 ], rest}
            end

          msg_updated = struct(msg, field)
          parse_key_value(rest, msg_updated)
        end
      )

      []
    )

    (
      @spec json_decode(iodata(), keyword()) :: {:ok, struct()} | {:error, any()}
      def json_decode(input, opts \\ []) do
        try do
          {:ok, json_decode!(input, opts)}
        rescue
          e in Protox.JsonDecodingError -> {:error, e}
        end
      end

      @spec json_decode!(iodata(), keyword()) :: struct() | no_return()
      def json_decode!(input, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :decode)

        Protox.JsonDecode.decode!(
          input,
          Entity.EntityAction,
          &json_library_wrapper.decode!(json_library, &1)
        )
      end

      @spec json_encode(struct(), keyword()) :: {:ok, iodata()} | {:error, any()}
      def json_encode(msg, opts \\ []) do
        try do
          {:ok, json_encode!(msg, opts)}
        rescue
          e in Protox.JsonEncodingError -> {:error, e}
        end
      end

      @spec json_encode!(struct(), keyword()) :: iodata() | no_return()
      def json_encode!(msg, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :encode)
        Protox.JsonEncode.encode!(msg, &json_library_wrapper.encode!(json_library, &1))
      end
    )

    (
      @deprecated "Use fields_defs()/0 instead"
      @spec defs() :: %{
              required(non_neg_integer) => {atom, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs() do
        %{
          1 => {:enter_scene, {:oneof, :action}, {:message, Entity.EnterScene}},
          2 => {:movement, {:oneof, :action}, {:message, Types.Movement}}
        }
      end

      @deprecated "Use fields_defs()/0 instead"
      @spec defs_by_name() :: %{
              required(atom) => {non_neg_integer, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs_by_name() do
        %{
          enter_scene: {1, {:oneof, :action}, {:message, Entity.EnterScene}},
          movement: {2, {:oneof, :action}, {:message, Types.Movement}}
        }
      end
    )

    (
      @spec fields_defs() :: list(Protox.Field.t())
      def fields_defs() do
        [
          %{
            __struct__: Protox.Field,
            json_name: "enterScene",
            kind: {:oneof, :action},
            label: :optional,
            name: :enter_scene,
            tag: 1,
            type: {:message, Entity.EnterScene}
          },
          %{
            __struct__: Protox.Field,
            json_name: "movement",
            kind: {:oneof, :action},
            label: :optional,
            name: :movement,
            tag: 2,
            type: {:message, Types.Movement}
          }
        ]
      end

      [
        @spec(field_def(atom) :: {:ok, Protox.Field.t()} | {:error, :no_such_field}),
        (
          def field_def(:enter_scene) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "enterScene",
               kind: {:oneof, :action},
               label: :optional,
               name: :enter_scene,
               tag: 1,
               type: {:message, Entity.EnterScene}
             }}
          end

          def field_def("enterScene") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "enterScene",
               kind: {:oneof, :action},
               label: :optional,
               name: :enter_scene,
               tag: 1,
               type: {:message, Entity.EnterScene}
             }}
          end

          def field_def("enter_scene") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "enterScene",
               kind: {:oneof, :action},
               label: :optional,
               name: :enter_scene,
               tag: 1,
               type: {:message, Entity.EnterScene}
             }}
          end
        ),
        (
          def field_def(:movement) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "movement",
               kind: {:oneof, :action},
               label: :optional,
               name: :movement,
               tag: 2,
               type: {:message, Types.Movement}
             }}
          end

          def field_def("movement") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "movement",
               kind: {:oneof, :action},
               label: :optional,
               name: :movement,
               tag: 2,
               type: {:message, Types.Movement}
             }}
          end

          []
        ),
        def field_def(_) do
          {:error, :no_such_field}
        end
      ]
    )

    (
      @spec unknown_fields(struct) :: [{non_neg_integer, Protox.Types.tag(), binary}]
      def unknown_fields(msg) do
        msg.__uf__
      end

      @spec unknown_fields_name() :: :__uf__
      def unknown_fields_name() do
        :__uf__
      end

      @spec clear_unknown_fields(struct) :: struct
      def clear_unknown_fields(msg) do
        struct!(msg, [{unknown_fields_name(), []}])
      end
    )

    (
      @spec required_fields() :: []
      def required_fields() do
        []
      end
    )

    (
      @spec syntax() :: atom()
      def syntax() do
        :proto3
      end
    )

    [
      @spec(default(atom) :: {:ok, boolean | integer | String.t() | float} | {:error, atom}),
      def default(:enter_scene) do
        {:error, :no_default_value}
      end,
      def default(:movement) do
        {:error, :no_default_value}
      end,
      def default(_) do
        {:error, :no_such_field}
      end
    ]

    (
      @spec file_options() :: nil
      def file_options() do
        nil
      end
    )
  end,
  defmodule Heartbeat do
    @moduledoc false
    defstruct timestamp: "", __uf__: []

    (
      (
        @spec encode(struct) :: {:ok, iodata} | {:error, any}
        def encode(msg) do
          try do
            {:ok, encode!(msg)}
          rescue
            e in [Protox.EncodingError, Protox.RequiredFieldsError] -> {:error, e}
          end
        end

        @spec encode!(struct) :: iodata | no_return
        def encode!(msg) do
          [] |> encode_timestamp(msg) |> encode_unknown_fields(msg)
        end
      )

      []

      [
        defp encode_timestamp(acc, msg) do
          try do
            if msg.timestamp == "" do
              acc
            else
              [acc, "\n", Protox.Encode.encode_string(msg.timestamp)]
            end
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:timestamp, "invalid field value"), __STACKTRACE__
          end
        end
      ]

      defp encode_unknown_fields(acc, msg) do
        Enum.reduce(msg.__struct__.unknown_fields(msg), acc, fn {tag, wire_type, bytes}, acc ->
          case wire_type do
            0 ->
              [acc, Protox.Encode.make_key_bytes(tag, :int32), bytes]

            1 ->
              [acc, Protox.Encode.make_key_bytes(tag, :double), bytes]

            2 ->
              len_bytes = bytes |> byte_size() |> Protox.Varint.encode()
              [acc, Protox.Encode.make_key_bytes(tag, :packed), len_bytes, bytes]

            5 ->
              [acc, Protox.Encode.make_key_bytes(tag, :float), bytes]
          end
        end)
      end
    )

    (
      (
        @spec decode(binary) :: {:ok, struct} | {:error, any}
        def decode(bytes) do
          try do
            {:ok, decode!(bytes)}
          rescue
            e in [Protox.DecodingError, Protox.IllegalTagError, Protox.RequiredFieldsError] ->
              {:error, e}
          end
        end

        (
          @spec decode!(binary) :: struct | no_return
          def decode!(bytes) do
            parse_key_value(bytes, struct(Heartbeat))
          end
        )
      )

      (
        @spec parse_key_value(binary, struct) :: struct
        defp parse_key_value(<<>>, msg) do
          msg
        end

        defp parse_key_value(bytes, msg) do
          {field, rest} =
            case Protox.Decode.parse_key(bytes) do
              {0, _, _} ->
                raise %Protox.IllegalTagError{}

              {1, _, bytes} ->
                {len, bytes} = Protox.Varint.decode(bytes)
                {delimited, rest} = Protox.Decode.parse_delimited(bytes, len)
                {[timestamp: delimited], rest}

              {tag, wire_type, rest} ->
                {value, rest} = Protox.Decode.parse_unknown(tag, wire_type, rest)

                {[
                   {msg.__struct__.unknown_fields_name,
                    [value | msg.__struct__.unknown_fields(msg)]}
                 ], rest}
            end

          msg_updated = struct(msg, field)
          parse_key_value(rest, msg_updated)
        end
      )

      []
    )

    (
      @spec json_decode(iodata(), keyword()) :: {:ok, struct()} | {:error, any()}
      def json_decode(input, opts \\ []) do
        try do
          {:ok, json_decode!(input, opts)}
        rescue
          e in Protox.JsonDecodingError -> {:error, e}
        end
      end

      @spec json_decode!(iodata(), keyword()) :: struct() | no_return()
      def json_decode!(input, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :decode)

        Protox.JsonDecode.decode!(
          input,
          Heartbeat,
          &json_library_wrapper.decode!(json_library, &1)
        )
      end

      @spec json_encode(struct(), keyword()) :: {:ok, iodata()} | {:error, any()}
      def json_encode(msg, opts \\ []) do
        try do
          {:ok, json_encode!(msg, opts)}
        rescue
          e in Protox.JsonEncodingError -> {:error, e}
        end
      end

      @spec json_encode!(struct(), keyword()) :: iodata() | no_return()
      def json_encode!(msg, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :encode)
        Protox.JsonEncode.encode!(msg, &json_library_wrapper.encode!(json_library, &1))
      end
    )

    (
      @deprecated "Use fields_defs()/0 instead"
      @spec defs() :: %{
              required(non_neg_integer) => {atom, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs() do
        %{1 => {:timestamp, {:scalar, ""}, :string}}
      end

      @deprecated "Use fields_defs()/0 instead"
      @spec defs_by_name() :: %{
              required(atom) => {non_neg_integer, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs_by_name() do
        %{timestamp: {1, {:scalar, ""}, :string}}
      end
    )

    (
      @spec fields_defs() :: list(Protox.Field.t())
      def fields_defs() do
        [
          %{
            __struct__: Protox.Field,
            json_name: "timestamp",
            kind: {:scalar, ""},
            label: :optional,
            name: :timestamp,
            tag: 1,
            type: :string
          }
        ]
      end

      [
        @spec(field_def(atom) :: {:ok, Protox.Field.t()} | {:error, :no_such_field}),
        (
          def field_def(:timestamp) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "timestamp",
               kind: {:scalar, ""},
               label: :optional,
               name: :timestamp,
               tag: 1,
               type: :string
             }}
          end

          def field_def("timestamp") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "timestamp",
               kind: {:scalar, ""},
               label: :optional,
               name: :timestamp,
               tag: 1,
               type: :string
             }}
          end

          []
        ),
        def field_def(_) do
          {:error, :no_such_field}
        end
      ]
    )

    (
      @spec unknown_fields(struct) :: [{non_neg_integer, Protox.Types.tag(), binary}]
      def unknown_fields(msg) do
        msg.__uf__
      end

      @spec unknown_fields_name() :: :__uf__
      def unknown_fields_name() do
        :__uf__
      end

      @spec clear_unknown_fields(struct) :: struct
      def clear_unknown_fields(msg) do
        struct!(msg, [{unknown_fields_name(), []}])
      end
    )

    (
      @spec required_fields() :: []
      def required_fields() do
        []
      end
    )

    (
      @spec syntax() :: atom()
      def syntax() do
        :proto3
      end
    )

    [
      @spec(default(atom) :: {:ok, boolean | integer | String.t() | float} | {:error, atom}),
      def default(:timestamp) do
        {:ok, ""}
      end,
      def default(_) do
        {:error, :no_such_field}
      end
    ]

    (
      @spec file_options() :: nil
      def file_options() do
        nil
      end
    )
  end,
  defmodule Packet do
    @moduledoc false
    defstruct id: 0, timestamp: 0, payload: nil, __uf__: []

    (
      (
        @spec encode(struct) :: {:ok, iodata} | {:error, any}
        def encode(msg) do
          try do
            {:ok, encode!(msg)}
          rescue
            e in [Protox.EncodingError, Protox.RequiredFieldsError] -> {:error, e}
          end
        end

        @spec encode!(struct) :: iodata | no_return
        def encode!(msg) do
          []
          |> encode_payload(msg)
          |> encode_id(msg)
          |> encode_timestamp(msg)
          |> encode_unknown_fields(msg)
        end
      )

      [
        defp encode_payload(acc, msg) do
          case msg.payload do
            nil -> acc
            {:heartbeat, _field_value} -> encode_heartbeat(acc, msg)
            {:entity_action, _field_value} -> encode_entity_action(acc, msg)
            {:broadcast_action, _field_value} -> encode_broadcast_action(acc, msg)
            {:result, _field_value} -> encode_result(acc, msg)
            {:time_sync, _field_value} -> encode_time_sync(acc, msg)
          end
        end
      ]

      [
        defp encode_id(acc, msg) do
          try do
            if msg.id == 0 do
              acc
            else
              [acc, "\b", Protox.Encode.encode_int64(msg.id)]
            end
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:id, "invalid field value"), __STACKTRACE__
          end
        end,
        defp encode_timestamp(acc, msg) do
          try do
            if msg.timestamp == 0 do
              acc
            else
              [acc, "\x10", Protox.Encode.encode_int64(msg.timestamp)]
            end
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:timestamp, "invalid field value"), __STACKTRACE__
          end
        end,
        defp encode_heartbeat(acc, msg) do
          try do
            {_, child_field_value} = msg.payload
            [acc, "\x1A", Protox.Encode.encode_message(child_field_value)]
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:heartbeat, "invalid field value"), __STACKTRACE__
          end
        end,
        defp encode_entity_action(acc, msg) do
          try do
            {_, child_field_value} = msg.payload
            [acc, "\"", Protox.Encode.encode_message(child_field_value)]
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:entity_action, "invalid field value"),
                      __STACKTRACE__
          end
        end,
        defp encode_broadcast_action(acc, msg) do
          try do
            {_, child_field_value} = msg.payload
            [acc, "*", Protox.Encode.encode_message(child_field_value)]
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:broadcast_action, "invalid field value"),
                      __STACKTRACE__
          end
        end,
        defp encode_result(acc, msg) do
          try do
            {_, child_field_value} = msg.payload
            [acc, "2", Protox.Encode.encode_message(child_field_value)]
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:result, "invalid field value"), __STACKTRACE__
          end
        end,
        defp encode_time_sync(acc, msg) do
          try do
            {_, child_field_value} = msg.payload
            [acc, ":", Protox.Encode.encode_message(child_field_value)]
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:time_sync, "invalid field value"), __STACKTRACE__
          end
        end
      ]

      defp encode_unknown_fields(acc, msg) do
        Enum.reduce(msg.__struct__.unknown_fields(msg), acc, fn {tag, wire_type, bytes}, acc ->
          case wire_type do
            0 ->
              [acc, Protox.Encode.make_key_bytes(tag, :int32), bytes]

            1 ->
              [acc, Protox.Encode.make_key_bytes(tag, :double), bytes]

            2 ->
              len_bytes = bytes |> byte_size() |> Protox.Varint.encode()
              [acc, Protox.Encode.make_key_bytes(tag, :packed), len_bytes, bytes]

            5 ->
              [acc, Protox.Encode.make_key_bytes(tag, :float), bytes]
          end
        end)
      end
    )

    (
      (
        @spec decode(binary) :: {:ok, struct} | {:error, any}
        def decode(bytes) do
          try do
            {:ok, decode!(bytes)}
          rescue
            e in [Protox.DecodingError, Protox.IllegalTagError, Protox.RequiredFieldsError] ->
              {:error, e}
          end
        end

        (
          @spec decode!(binary) :: struct | no_return
          def decode!(bytes) do
            parse_key_value(bytes, struct(Packet))
          end
        )
      )

      (
        @spec parse_key_value(binary, struct) :: struct
        defp parse_key_value(<<>>, msg) do
          msg
        end

        defp parse_key_value(bytes, msg) do
          {field, rest} =
            case Protox.Decode.parse_key(bytes) do
              {0, _, _} ->
                raise %Protox.IllegalTagError{}

              {1, _, bytes} ->
                {value, rest} = Protox.Decode.parse_int64(bytes)
                {[id: value], rest}

              {2, _, bytes} ->
                {value, rest} = Protox.Decode.parse_int64(bytes)
                {[timestamp: value], rest}

              {3, _, bytes} ->
                {len, bytes} = Protox.Varint.decode(bytes)
                {delimited, rest} = Protox.Decode.parse_delimited(bytes, len)

                {[
                   case msg.payload do
                     {:heartbeat, previous_value} ->
                       {:payload,
                        {:heartbeat,
                         Protox.MergeMessage.merge(previous_value, Heartbeat.decode!(delimited))}}

                     _ ->
                       {:payload, {:heartbeat, Heartbeat.decode!(delimited)}}
                   end
                 ], rest}

              {4, _, bytes} ->
                {len, bytes} = Protox.Varint.decode(bytes)
                {delimited, rest} = Protox.Decode.parse_delimited(bytes, len)

                {[
                   case msg.payload do
                     {:entity_action, previous_value} ->
                       {:payload,
                        {:entity_action,
                         Protox.MergeMessage.merge(
                           previous_value,
                           Entity.EntityAction.decode!(delimited)
                         )}}

                     _ ->
                       {:payload, {:entity_action, Entity.EntityAction.decode!(delimited)}}
                   end
                 ], rest}

              {5, _, bytes} ->
                {len, bytes} = Protox.Varint.decode(bytes)
                {delimited, rest} = Protox.Decode.parse_delimited(bytes, len)

                {[
                   case msg.payload do
                     {:broadcast_action, previous_value} ->
                       {:payload,
                        {:broadcast_action,
                         Protox.MergeMessage.merge(
                           previous_value,
                           Broadcast.Player.Action.decode!(delimited)
                         )}}

                     _ ->
                       {:payload, {:broadcast_action, Broadcast.Player.Action.decode!(delimited)}}
                   end
                 ], rest}

              {6, _, bytes} ->
                {len, bytes} = Protox.Varint.decode(bytes)
                {delimited, rest} = Protox.Decode.parse_delimited(bytes, len)

                {[
                   case msg.payload do
                     {:result, previous_value} ->
                       {:payload,
                        {:result,
                         Protox.MergeMessage.merge(
                           previous_value,
                           Reply.Result.decode!(delimited)
                         )}}

                     _ ->
                       {:payload, {:result, Reply.Result.decode!(delimited)}}
                   end
                 ], rest}

              {7, _, bytes} ->
                {len, bytes} = Protox.Varint.decode(bytes)
                {delimited, rest} = Protox.Decode.parse_delimited(bytes, len)

                {[
                   case msg.payload do
                     {:time_sync, previous_value} ->
                       {:payload,
                        {:time_sync,
                         Protox.MergeMessage.merge(previous_value, TimeSync.decode!(delimited))}}

                     _ ->
                       {:payload, {:time_sync, TimeSync.decode!(delimited)}}
                   end
                 ], rest}

              {tag, wire_type, rest} ->
                {value, rest} = Protox.Decode.parse_unknown(tag, wire_type, rest)

                {[
                   {msg.__struct__.unknown_fields_name,
                    [value | msg.__struct__.unknown_fields(msg)]}
                 ], rest}
            end

          msg_updated = struct(msg, field)
          parse_key_value(rest, msg_updated)
        end
      )

      []
    )

    (
      @spec json_decode(iodata(), keyword()) :: {:ok, struct()} | {:error, any()}
      def json_decode(input, opts \\ []) do
        try do
          {:ok, json_decode!(input, opts)}
        rescue
          e in Protox.JsonDecodingError -> {:error, e}
        end
      end

      @spec json_decode!(iodata(), keyword()) :: struct() | no_return()
      def json_decode!(input, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :decode)
        Protox.JsonDecode.decode!(input, Packet, &json_library_wrapper.decode!(json_library, &1))
      end

      @spec json_encode(struct(), keyword()) :: {:ok, iodata()} | {:error, any()}
      def json_encode(msg, opts \\ []) do
        try do
          {:ok, json_encode!(msg, opts)}
        rescue
          e in Protox.JsonEncodingError -> {:error, e}
        end
      end

      @spec json_encode!(struct(), keyword()) :: iodata() | no_return()
      def json_encode!(msg, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :encode)
        Protox.JsonEncode.encode!(msg, &json_library_wrapper.encode!(json_library, &1))
      end
    )

    (
      @deprecated "Use fields_defs()/0 instead"
      @spec defs() :: %{
              required(non_neg_integer) => {atom, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs() do
        %{
          1 => {:id, {:scalar, 0}, :int64},
          2 => {:timestamp, {:scalar, 0}, :int64},
          3 => {:heartbeat, {:oneof, :payload}, {:message, Heartbeat}},
          4 => {:entity_action, {:oneof, :payload}, {:message, Entity.EntityAction}},
          5 => {:broadcast_action, {:oneof, :payload}, {:message, Broadcast.Player.Action}},
          6 => {:result, {:oneof, :payload}, {:message, Reply.Result}},
          7 => {:time_sync, {:oneof, :payload}, {:message, TimeSync}}
        }
      end

      @deprecated "Use fields_defs()/0 instead"
      @spec defs_by_name() :: %{
              required(atom) => {non_neg_integer, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs_by_name() do
        %{
          broadcast_action: {5, {:oneof, :payload}, {:message, Broadcast.Player.Action}},
          entity_action: {4, {:oneof, :payload}, {:message, Entity.EntityAction}},
          heartbeat: {3, {:oneof, :payload}, {:message, Heartbeat}},
          id: {1, {:scalar, 0}, :int64},
          result: {6, {:oneof, :payload}, {:message, Reply.Result}},
          time_sync: {7, {:oneof, :payload}, {:message, TimeSync}},
          timestamp: {2, {:scalar, 0}, :int64}
        }
      end
    )

    (
      @spec fields_defs() :: list(Protox.Field.t())
      def fields_defs() do
        [
          %{
            __struct__: Protox.Field,
            json_name: "id",
            kind: {:scalar, 0},
            label: :optional,
            name: :id,
            tag: 1,
            type: :int64
          },
          %{
            __struct__: Protox.Field,
            json_name: "timestamp",
            kind: {:scalar, 0},
            label: :optional,
            name: :timestamp,
            tag: 2,
            type: :int64
          },
          %{
            __struct__: Protox.Field,
            json_name: "heartbeat",
            kind: {:oneof, :payload},
            label: :optional,
            name: :heartbeat,
            tag: 3,
            type: {:message, Heartbeat}
          },
          %{
            __struct__: Protox.Field,
            json_name: "entityAction",
            kind: {:oneof, :payload},
            label: :optional,
            name: :entity_action,
            tag: 4,
            type: {:message, Entity.EntityAction}
          },
          %{
            __struct__: Protox.Field,
            json_name: "broadcastAction",
            kind: {:oneof, :payload},
            label: :optional,
            name: :broadcast_action,
            tag: 5,
            type: {:message, Broadcast.Player.Action}
          },
          %{
            __struct__: Protox.Field,
            json_name: "result",
            kind: {:oneof, :payload},
            label: :optional,
            name: :result,
            tag: 6,
            type: {:message, Reply.Result}
          },
          %{
            __struct__: Protox.Field,
            json_name: "timeSync",
            kind: {:oneof, :payload},
            label: :optional,
            name: :time_sync,
            tag: 7,
            type: {:message, TimeSync}
          }
        ]
      end

      [
        @spec(field_def(atom) :: {:ok, Protox.Field.t()} | {:error, :no_such_field}),
        (
          def field_def(:id) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "id",
               kind: {:scalar, 0},
               label: :optional,
               name: :id,
               tag: 1,
               type: :int64
             }}
          end

          def field_def("id") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "id",
               kind: {:scalar, 0},
               label: :optional,
               name: :id,
               tag: 1,
               type: :int64
             }}
          end

          []
        ),
        (
          def field_def(:timestamp) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "timestamp",
               kind: {:scalar, 0},
               label: :optional,
               name: :timestamp,
               tag: 2,
               type: :int64
             }}
          end

          def field_def("timestamp") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "timestamp",
               kind: {:scalar, 0},
               label: :optional,
               name: :timestamp,
               tag: 2,
               type: :int64
             }}
          end

          []
        ),
        (
          def field_def(:heartbeat) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "heartbeat",
               kind: {:oneof, :payload},
               label: :optional,
               name: :heartbeat,
               tag: 3,
               type: {:message, Heartbeat}
             }}
          end

          def field_def("heartbeat") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "heartbeat",
               kind: {:oneof, :payload},
               label: :optional,
               name: :heartbeat,
               tag: 3,
               type: {:message, Heartbeat}
             }}
          end

          []
        ),
        (
          def field_def(:entity_action) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "entityAction",
               kind: {:oneof, :payload},
               label: :optional,
               name: :entity_action,
               tag: 4,
               type: {:message, Entity.EntityAction}
             }}
          end

          def field_def("entityAction") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "entityAction",
               kind: {:oneof, :payload},
               label: :optional,
               name: :entity_action,
               tag: 4,
               type: {:message, Entity.EntityAction}
             }}
          end

          def field_def("entity_action") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "entityAction",
               kind: {:oneof, :payload},
               label: :optional,
               name: :entity_action,
               tag: 4,
               type: {:message, Entity.EntityAction}
             }}
          end
        ),
        (
          def field_def(:broadcast_action) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "broadcastAction",
               kind: {:oneof, :payload},
               label: :optional,
               name: :broadcast_action,
               tag: 5,
               type: {:message, Broadcast.Player.Action}
             }}
          end

          def field_def("broadcastAction") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "broadcastAction",
               kind: {:oneof, :payload},
               label: :optional,
               name: :broadcast_action,
               tag: 5,
               type: {:message, Broadcast.Player.Action}
             }}
          end

          def field_def("broadcast_action") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "broadcastAction",
               kind: {:oneof, :payload},
               label: :optional,
               name: :broadcast_action,
               tag: 5,
               type: {:message, Broadcast.Player.Action}
             }}
          end
        ),
        (
          def field_def(:result) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "result",
               kind: {:oneof, :payload},
               label: :optional,
               name: :result,
               tag: 6,
               type: {:message, Reply.Result}
             }}
          end

          def field_def("result") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "result",
               kind: {:oneof, :payload},
               label: :optional,
               name: :result,
               tag: 6,
               type: {:message, Reply.Result}
             }}
          end

          []
        ),
        (
          def field_def(:time_sync) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "timeSync",
               kind: {:oneof, :payload},
               label: :optional,
               name: :time_sync,
               tag: 7,
               type: {:message, TimeSync}
             }}
          end

          def field_def("timeSync") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "timeSync",
               kind: {:oneof, :payload},
               label: :optional,
               name: :time_sync,
               tag: 7,
               type: {:message, TimeSync}
             }}
          end

          def field_def("time_sync") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "timeSync",
               kind: {:oneof, :payload},
               label: :optional,
               name: :time_sync,
               tag: 7,
               type: {:message, TimeSync}
             }}
          end
        ),
        def field_def(_) do
          {:error, :no_such_field}
        end
      ]
    )

    (
      @spec unknown_fields(struct) :: [{non_neg_integer, Protox.Types.tag(), binary}]
      def unknown_fields(msg) do
        msg.__uf__
      end

      @spec unknown_fields_name() :: :__uf__
      def unknown_fields_name() do
        :__uf__
      end

      @spec clear_unknown_fields(struct) :: struct
      def clear_unknown_fields(msg) do
        struct!(msg, [{unknown_fields_name(), []}])
      end
    )

    (
      @spec required_fields() :: []
      def required_fields() do
        []
      end
    )

    (
      @spec syntax() :: atom()
      def syntax() do
        :proto3
      end
    )

    [
      @spec(default(atom) :: {:ok, boolean | integer | String.t() | float} | {:error, atom}),
      def default(:id) do
        {:ok, 0}
      end,
      def default(:timestamp) do
        {:ok, 0}
      end,
      def default(:heartbeat) do
        {:error, :no_default_value}
      end,
      def default(:entity_action) do
        {:error, :no_default_value}
      end,
      def default(:broadcast_action) do
        {:error, :no_default_value}
      end,
      def default(:result) do
        {:error, :no_default_value}
      end,
      def default(:time_sync) do
        {:error, :no_default_value}
      end,
      def default(_) do
        {:error, :no_such_field}
      end
    ]

    (
      @spec file_options() :: nil
      def file_options() do
        nil
      end
    )
  end,
  defmodule Reply.EnterScene do
    @moduledoc false
    defstruct location: nil, __uf__: []

    (
      (
        @spec encode(struct) :: {:ok, iodata} | {:error, any}
        def encode(msg) do
          try do
            {:ok, encode!(msg)}
          rescue
            e in [Protox.EncodingError, Protox.RequiredFieldsError] -> {:error, e}
          end
        end

        @spec encode!(struct) :: iodata | no_return
        def encode!(msg) do
          [] |> encode_location(msg) |> encode_unknown_fields(msg)
        end
      )

      []

      [
        defp encode_location(acc, msg) do
          try do
            if msg.location == nil do
              acc
            else
              [acc, "\n", Protox.Encode.encode_message(msg.location)]
            end
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:location, "invalid field value"), __STACKTRACE__
          end
        end
      ]

      defp encode_unknown_fields(acc, msg) do
        Enum.reduce(msg.__struct__.unknown_fields(msg), acc, fn {tag, wire_type, bytes}, acc ->
          case wire_type do
            0 ->
              [acc, Protox.Encode.make_key_bytes(tag, :int32), bytes]

            1 ->
              [acc, Protox.Encode.make_key_bytes(tag, :double), bytes]

            2 ->
              len_bytes = bytes |> byte_size() |> Protox.Varint.encode()
              [acc, Protox.Encode.make_key_bytes(tag, :packed), len_bytes, bytes]

            5 ->
              [acc, Protox.Encode.make_key_bytes(tag, :float), bytes]
          end
        end)
      end
    )

    (
      (
        @spec decode(binary) :: {:ok, struct} | {:error, any}
        def decode(bytes) do
          try do
            {:ok, decode!(bytes)}
          rescue
            e in [Protox.DecodingError, Protox.IllegalTagError, Protox.RequiredFieldsError] ->
              {:error, e}
          end
        end

        (
          @spec decode!(binary) :: struct | no_return
          def decode!(bytes) do
            parse_key_value(bytes, struct(Reply.EnterScene))
          end
        )
      )

      (
        @spec parse_key_value(binary, struct) :: struct
        defp parse_key_value(<<>>, msg) do
          msg
        end

        defp parse_key_value(bytes, msg) do
          {field, rest} =
            case Protox.Decode.parse_key(bytes) do
              {0, _, _} ->
                raise %Protox.IllegalTagError{}

              {1, _, bytes} ->
                {len, bytes} = Protox.Varint.decode(bytes)
                {delimited, rest} = Protox.Decode.parse_delimited(bytes, len)

                {[
                   location:
                     Protox.MergeMessage.merge(msg.location, Types.Vector.decode!(delimited))
                 ], rest}

              {tag, wire_type, rest} ->
                {value, rest} = Protox.Decode.parse_unknown(tag, wire_type, rest)

                {[
                   {msg.__struct__.unknown_fields_name,
                    [value | msg.__struct__.unknown_fields(msg)]}
                 ], rest}
            end

          msg_updated = struct(msg, field)
          parse_key_value(rest, msg_updated)
        end
      )

      []
    )

    (
      @spec json_decode(iodata(), keyword()) :: {:ok, struct()} | {:error, any()}
      def json_decode(input, opts \\ []) do
        try do
          {:ok, json_decode!(input, opts)}
        rescue
          e in Protox.JsonDecodingError -> {:error, e}
        end
      end

      @spec json_decode!(iodata(), keyword()) :: struct() | no_return()
      def json_decode!(input, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :decode)

        Protox.JsonDecode.decode!(
          input,
          Reply.EnterScene,
          &json_library_wrapper.decode!(json_library, &1)
        )
      end

      @spec json_encode(struct(), keyword()) :: {:ok, iodata()} | {:error, any()}
      def json_encode(msg, opts \\ []) do
        try do
          {:ok, json_encode!(msg, opts)}
        rescue
          e in Protox.JsonEncodingError -> {:error, e}
        end
      end

      @spec json_encode!(struct(), keyword()) :: iodata() | no_return()
      def json_encode!(msg, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :encode)
        Protox.JsonEncode.encode!(msg, &json_library_wrapper.encode!(json_library, &1))
      end
    )

    (
      @deprecated "Use fields_defs()/0 instead"
      @spec defs() :: %{
              required(non_neg_integer) => {atom, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs() do
        %{1 => {:location, {:scalar, nil}, {:message, Types.Vector}}}
      end

      @deprecated "Use fields_defs()/0 instead"
      @spec defs_by_name() :: %{
              required(atom) => {non_neg_integer, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs_by_name() do
        %{location: {1, {:scalar, nil}, {:message, Types.Vector}}}
      end
    )

    (
      @spec fields_defs() :: list(Protox.Field.t())
      def fields_defs() do
        [
          %{
            __struct__: Protox.Field,
            json_name: "location",
            kind: {:scalar, nil},
            label: :optional,
            name: :location,
            tag: 1,
            type: {:message, Types.Vector}
          }
        ]
      end

      [
        @spec(field_def(atom) :: {:ok, Protox.Field.t()} | {:error, :no_such_field}),
        (
          def field_def(:location) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "location",
               kind: {:scalar, nil},
               label: :optional,
               name: :location,
               tag: 1,
               type: {:message, Types.Vector}
             }}
          end

          def field_def("location") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "location",
               kind: {:scalar, nil},
               label: :optional,
               name: :location,
               tag: 1,
               type: {:message, Types.Vector}
             }}
          end

          []
        ),
        def field_def(_) do
          {:error, :no_such_field}
        end
      ]
    )

    (
      @spec unknown_fields(struct) :: [{non_neg_integer, Protox.Types.tag(), binary}]
      def unknown_fields(msg) do
        msg.__uf__
      end

      @spec unknown_fields_name() :: :__uf__
      def unknown_fields_name() do
        :__uf__
      end

      @spec clear_unknown_fields(struct) :: struct
      def clear_unknown_fields(msg) do
        struct!(msg, [{unknown_fields_name(), []}])
      end
    )

    (
      @spec required_fields() :: []
      def required_fields() do
        []
      end
    )

    (
      @spec syntax() :: atom()
      def syntax() do
        :proto3
      end
    )

    [
      @spec(default(atom) :: {:ok, boolean | integer | String.t() | float} | {:error, atom}),
      def default(:location) do
        {:ok, nil}
      end,
      def default(_) do
        {:error, :no_such_field}
      end
    ]

    (
      @spec file_options() :: nil
      def file_options() do
        nil
      end
    )
  end,
  defmodule Reply.PlayerInfo do
    @moduledoc false
    defstruct cid: 0, location: nil, __uf__: []

    (
      (
        @spec encode(struct) :: {:ok, iodata} | {:error, any}
        def encode(msg) do
          try do
            {:ok, encode!(msg)}
          rescue
            e in [Protox.EncodingError, Protox.RequiredFieldsError] -> {:error, e}
          end
        end

        @spec encode!(struct) :: iodata | no_return
        def encode!(msg) do
          [] |> encode_cid(msg) |> encode_location(msg) |> encode_unknown_fields(msg)
        end
      )

      []

      [
        defp encode_cid(acc, msg) do
          try do
            if msg.cid == 0 do
              acc
            else
              [acc, "\b", Protox.Encode.encode_int64(msg.cid)]
            end
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:cid, "invalid field value"), __STACKTRACE__
          end
        end,
        defp encode_location(acc, msg) do
          try do
            if msg.location == nil do
              acc
            else
              [acc, "\x12", Protox.Encode.encode_message(msg.location)]
            end
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:location, "invalid field value"), __STACKTRACE__
          end
        end
      ]

      defp encode_unknown_fields(acc, msg) do
        Enum.reduce(msg.__struct__.unknown_fields(msg), acc, fn {tag, wire_type, bytes}, acc ->
          case wire_type do
            0 ->
              [acc, Protox.Encode.make_key_bytes(tag, :int32), bytes]

            1 ->
              [acc, Protox.Encode.make_key_bytes(tag, :double), bytes]

            2 ->
              len_bytes = bytes |> byte_size() |> Protox.Varint.encode()
              [acc, Protox.Encode.make_key_bytes(tag, :packed), len_bytes, bytes]

            5 ->
              [acc, Protox.Encode.make_key_bytes(tag, :float), bytes]
          end
        end)
      end
    )

    (
      (
        @spec decode(binary) :: {:ok, struct} | {:error, any}
        def decode(bytes) do
          try do
            {:ok, decode!(bytes)}
          rescue
            e in [Protox.DecodingError, Protox.IllegalTagError, Protox.RequiredFieldsError] ->
              {:error, e}
          end
        end

        (
          @spec decode!(binary) :: struct | no_return
          def decode!(bytes) do
            parse_key_value(bytes, struct(Reply.PlayerInfo))
          end
        )
      )

      (
        @spec parse_key_value(binary, struct) :: struct
        defp parse_key_value(<<>>, msg) do
          msg
        end

        defp parse_key_value(bytes, msg) do
          {field, rest} =
            case Protox.Decode.parse_key(bytes) do
              {0, _, _} ->
                raise %Protox.IllegalTagError{}

              {1, _, bytes} ->
                {value, rest} = Protox.Decode.parse_int64(bytes)
                {[cid: value], rest}

              {2, _, bytes} ->
                {len, bytes} = Protox.Varint.decode(bytes)
                {delimited, rest} = Protox.Decode.parse_delimited(bytes, len)

                {[
                   location:
                     Protox.MergeMessage.merge(msg.location, Types.Vector.decode!(delimited))
                 ], rest}

              {tag, wire_type, rest} ->
                {value, rest} = Protox.Decode.parse_unknown(tag, wire_type, rest)

                {[
                   {msg.__struct__.unknown_fields_name,
                    [value | msg.__struct__.unknown_fields(msg)]}
                 ], rest}
            end

          msg_updated = struct(msg, field)
          parse_key_value(rest, msg_updated)
        end
      )

      []
    )

    (
      @spec json_decode(iodata(), keyword()) :: {:ok, struct()} | {:error, any()}
      def json_decode(input, opts \\ []) do
        try do
          {:ok, json_decode!(input, opts)}
        rescue
          e in Protox.JsonDecodingError -> {:error, e}
        end
      end

      @spec json_decode!(iodata(), keyword()) :: struct() | no_return()
      def json_decode!(input, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :decode)

        Protox.JsonDecode.decode!(
          input,
          Reply.PlayerInfo,
          &json_library_wrapper.decode!(json_library, &1)
        )
      end

      @spec json_encode(struct(), keyword()) :: {:ok, iodata()} | {:error, any()}
      def json_encode(msg, opts \\ []) do
        try do
          {:ok, json_encode!(msg, opts)}
        rescue
          e in Protox.JsonEncodingError -> {:error, e}
        end
      end

      @spec json_encode!(struct(), keyword()) :: iodata() | no_return()
      def json_encode!(msg, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :encode)
        Protox.JsonEncode.encode!(msg, &json_library_wrapper.encode!(json_library, &1))
      end
    )

    (
      @deprecated "Use fields_defs()/0 instead"
      @spec defs() :: %{
              required(non_neg_integer) => {atom, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs() do
        %{
          1 => {:cid, {:scalar, 0}, :int64},
          2 => {:location, {:scalar, nil}, {:message, Types.Vector}}
        }
      end

      @deprecated "Use fields_defs()/0 instead"
      @spec defs_by_name() :: %{
              required(atom) => {non_neg_integer, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs_by_name() do
        %{cid: {1, {:scalar, 0}, :int64}, location: {2, {:scalar, nil}, {:message, Types.Vector}}}
      end
    )

    (
      @spec fields_defs() :: list(Protox.Field.t())
      def fields_defs() do
        [
          %{
            __struct__: Protox.Field,
            json_name: "cid",
            kind: {:scalar, 0},
            label: :optional,
            name: :cid,
            tag: 1,
            type: :int64
          },
          %{
            __struct__: Protox.Field,
            json_name: "location",
            kind: {:scalar, nil},
            label: :optional,
            name: :location,
            tag: 2,
            type: {:message, Types.Vector}
          }
        ]
      end

      [
        @spec(field_def(atom) :: {:ok, Protox.Field.t()} | {:error, :no_such_field}),
        (
          def field_def(:cid) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "cid",
               kind: {:scalar, 0},
               label: :optional,
               name: :cid,
               tag: 1,
               type: :int64
             }}
          end

          def field_def("cid") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "cid",
               kind: {:scalar, 0},
               label: :optional,
               name: :cid,
               tag: 1,
               type: :int64
             }}
          end

          []
        ),
        (
          def field_def(:location) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "location",
               kind: {:scalar, nil},
               label: :optional,
               name: :location,
               tag: 2,
               type: {:message, Types.Vector}
             }}
          end

          def field_def("location") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "location",
               kind: {:scalar, nil},
               label: :optional,
               name: :location,
               tag: 2,
               type: {:message, Types.Vector}
             }}
          end

          []
        ),
        def field_def(_) do
          {:error, :no_such_field}
        end
      ]
    )

    (
      @spec unknown_fields(struct) :: [{non_neg_integer, Protox.Types.tag(), binary}]
      def unknown_fields(msg) do
        msg.__uf__
      end

      @spec unknown_fields_name() :: :__uf__
      def unknown_fields_name() do
        :__uf__
      end

      @spec clear_unknown_fields(struct) :: struct
      def clear_unknown_fields(msg) do
        struct!(msg, [{unknown_fields_name(), []}])
      end
    )

    (
      @spec required_fields() :: []
      def required_fields() do
        []
      end
    )

    (
      @spec syntax() :: atom()
      def syntax() do
        :proto3
      end
    )

    [
      @spec(default(atom) :: {:ok, boolean | integer | String.t() | float} | {:error, atom}),
      def default(:cid) do
        {:ok, 0}
      end,
      def default(:location) do
        {:ok, nil}
      end,
      def default(_) do
        {:error, :no_such_field}
      end
    ]

    (
      @spec file_options() :: nil
      def file_options() do
        nil
      end
    )
  end,
  defmodule Reply.PlayerMove do
    @moduledoc false
    defstruct cid: 0, location: nil, __uf__: []

    (
      (
        @spec encode(struct) :: {:ok, iodata} | {:error, any}
        def encode(msg) do
          try do
            {:ok, encode!(msg)}
          rescue
            e in [Protox.EncodingError, Protox.RequiredFieldsError] -> {:error, e}
          end
        end

        @spec encode!(struct) :: iodata | no_return
        def encode!(msg) do
          [] |> encode_cid(msg) |> encode_location(msg) |> encode_unknown_fields(msg)
        end
      )

      []

      [
        defp encode_cid(acc, msg) do
          try do
            if msg.cid == 0 do
              acc
            else
              [acc, "\b", Protox.Encode.encode_int64(msg.cid)]
            end
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:cid, "invalid field value"), __STACKTRACE__
          end
        end,
        defp encode_location(acc, msg) do
          try do
            if msg.location == nil do
              acc
            else
              [acc, "\x12", Protox.Encode.encode_message(msg.location)]
            end
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:location, "invalid field value"), __STACKTRACE__
          end
        end
      ]

      defp encode_unknown_fields(acc, msg) do
        Enum.reduce(msg.__struct__.unknown_fields(msg), acc, fn {tag, wire_type, bytes}, acc ->
          case wire_type do
            0 ->
              [acc, Protox.Encode.make_key_bytes(tag, :int32), bytes]

            1 ->
              [acc, Protox.Encode.make_key_bytes(tag, :double), bytes]

            2 ->
              len_bytes = bytes |> byte_size() |> Protox.Varint.encode()
              [acc, Protox.Encode.make_key_bytes(tag, :packed), len_bytes, bytes]

            5 ->
              [acc, Protox.Encode.make_key_bytes(tag, :float), bytes]
          end
        end)
      end
    )

    (
      (
        @spec decode(binary) :: {:ok, struct} | {:error, any}
        def decode(bytes) do
          try do
            {:ok, decode!(bytes)}
          rescue
            e in [Protox.DecodingError, Protox.IllegalTagError, Protox.RequiredFieldsError] ->
              {:error, e}
          end
        end

        (
          @spec decode!(binary) :: struct | no_return
          def decode!(bytes) do
            parse_key_value(bytes, struct(Reply.PlayerMove))
          end
        )
      )

      (
        @spec parse_key_value(binary, struct) :: struct
        defp parse_key_value(<<>>, msg) do
          msg
        end

        defp parse_key_value(bytes, msg) do
          {field, rest} =
            case Protox.Decode.parse_key(bytes) do
              {0, _, _} ->
                raise %Protox.IllegalTagError{}

              {1, _, bytes} ->
                {value, rest} = Protox.Decode.parse_int64(bytes)
                {[cid: value], rest}

              {2, _, bytes} ->
                {len, bytes} = Protox.Varint.decode(bytes)
                {delimited, rest} = Protox.Decode.parse_delimited(bytes, len)

                {[
                   location:
                     Protox.MergeMessage.merge(msg.location, Types.Vector.decode!(delimited))
                 ], rest}

              {tag, wire_type, rest} ->
                {value, rest} = Protox.Decode.parse_unknown(tag, wire_type, rest)

                {[
                   {msg.__struct__.unknown_fields_name,
                    [value | msg.__struct__.unknown_fields(msg)]}
                 ], rest}
            end

          msg_updated = struct(msg, field)
          parse_key_value(rest, msg_updated)
        end
      )

      []
    )

    (
      @spec json_decode(iodata(), keyword()) :: {:ok, struct()} | {:error, any()}
      def json_decode(input, opts \\ []) do
        try do
          {:ok, json_decode!(input, opts)}
        rescue
          e in Protox.JsonDecodingError -> {:error, e}
        end
      end

      @spec json_decode!(iodata(), keyword()) :: struct() | no_return()
      def json_decode!(input, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :decode)

        Protox.JsonDecode.decode!(
          input,
          Reply.PlayerMove,
          &json_library_wrapper.decode!(json_library, &1)
        )
      end

      @spec json_encode(struct(), keyword()) :: {:ok, iodata()} | {:error, any()}
      def json_encode(msg, opts \\ []) do
        try do
          {:ok, json_encode!(msg, opts)}
        rescue
          e in Protox.JsonEncodingError -> {:error, e}
        end
      end

      @spec json_encode!(struct(), keyword()) :: iodata() | no_return()
      def json_encode!(msg, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :encode)
        Protox.JsonEncode.encode!(msg, &json_library_wrapper.encode!(json_library, &1))
      end
    )

    (
      @deprecated "Use fields_defs()/0 instead"
      @spec defs() :: %{
              required(non_neg_integer) => {atom, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs() do
        %{
          1 => {:cid, {:scalar, 0}, :int64},
          2 => {:location, {:scalar, nil}, {:message, Types.Vector}}
        }
      end

      @deprecated "Use fields_defs()/0 instead"
      @spec defs_by_name() :: %{
              required(atom) => {non_neg_integer, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs_by_name() do
        %{cid: {1, {:scalar, 0}, :int64}, location: {2, {:scalar, nil}, {:message, Types.Vector}}}
      end
    )

    (
      @spec fields_defs() :: list(Protox.Field.t())
      def fields_defs() do
        [
          %{
            __struct__: Protox.Field,
            json_name: "cid",
            kind: {:scalar, 0},
            label: :optional,
            name: :cid,
            tag: 1,
            type: :int64
          },
          %{
            __struct__: Protox.Field,
            json_name: "location",
            kind: {:scalar, nil},
            label: :optional,
            name: :location,
            tag: 2,
            type: {:message, Types.Vector}
          }
        ]
      end

      [
        @spec(field_def(atom) :: {:ok, Protox.Field.t()} | {:error, :no_such_field}),
        (
          def field_def(:cid) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "cid",
               kind: {:scalar, 0},
               label: :optional,
               name: :cid,
               tag: 1,
               type: :int64
             }}
          end

          def field_def("cid") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "cid",
               kind: {:scalar, 0},
               label: :optional,
               name: :cid,
               tag: 1,
               type: :int64
             }}
          end

          []
        ),
        (
          def field_def(:location) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "location",
               kind: {:scalar, nil},
               label: :optional,
               name: :location,
               tag: 2,
               type: {:message, Types.Vector}
             }}
          end

          def field_def("location") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "location",
               kind: {:scalar, nil},
               label: :optional,
               name: :location,
               tag: 2,
               type: {:message, Types.Vector}
             }}
          end

          []
        ),
        def field_def(_) do
          {:error, :no_such_field}
        end
      ]
    )

    (
      @spec unknown_fields(struct) :: [{non_neg_integer, Protox.Types.tag(), binary}]
      def unknown_fields(msg) do
        msg.__uf__
      end

      @spec unknown_fields_name() :: :__uf__
      def unknown_fields_name() do
        :__uf__
      end

      @spec clear_unknown_fields(struct) :: struct
      def clear_unknown_fields(msg) do
        struct!(msg, [{unknown_fields_name(), []}])
      end
    )

    (
      @spec required_fields() :: []
      def required_fields() do
        []
      end
    )

    (
      @spec syntax() :: atom()
      def syntax() do
        :proto3
      end
    )

    [
      @spec(default(atom) :: {:ok, boolean | integer | String.t() | float} | {:error, atom}),
      def default(:cid) do
        {:ok, 0}
      end,
      def default(:location) do
        {:ok, nil}
      end,
      def default(_) do
        {:error, :no_such_field}
      end
    ]

    (
      @spec file_options() :: nil
      def file_options() do
        nil
      end
    )
  end,
  defmodule Reply.Result do
    @moduledoc false
    defstruct packet_id: 0, status_code: :ok, payload: nil, __uf__: []

    (
      (
        @spec encode(struct) :: {:ok, iodata} | {:error, any}
        def encode(msg) do
          try do
            {:ok, encode!(msg)}
          rescue
            e in [Protox.EncodingError, Protox.RequiredFieldsError] -> {:error, e}
          end
        end

        @spec encode!(struct) :: iodata | no_return
        def encode!(msg) do
          []
          |> encode_payload(msg)
          |> encode_packet_id(msg)
          |> encode_status_code(msg)
          |> encode_unknown_fields(msg)
        end
      )

      [
        defp encode_payload(acc, msg) do
          case msg.payload do
            nil -> acc
            {:enter_scene, _field_value} -> encode_enter_scene(acc, msg)
            {:player_move, _field_value} -> encode_player_move(acc, msg)
          end
        end
      ]

      [
        defp encode_packet_id(acc, msg) do
          try do
            if msg.packet_id == 0 do
              acc
            else
              [acc, "\b", Protox.Encode.encode_int64(msg.packet_id)]
            end
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:packet_id, "invalid field value"), __STACKTRACE__
          end
        end,
        defp encode_status_code(acc, msg) do
          try do
            if msg.status_code == :ok do
              acc
            else
              [
                acc,
                "\x10",
                msg.status_code |> Reply.StatusCode.encode() |> Protox.Encode.encode_enum()
              ]
            end
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:status_code, "invalid field value"),
                      __STACKTRACE__
          end
        end,
        defp encode_enter_scene(acc, msg) do
          try do
            {_, child_field_value} = msg.payload
            [acc, "\x1A", Protox.Encode.encode_message(child_field_value)]
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:enter_scene, "invalid field value"),
                      __STACKTRACE__
          end
        end,
        defp encode_player_move(acc, msg) do
          try do
            {_, child_field_value} = msg.payload
            [acc, "\"", Protox.Encode.encode_message(child_field_value)]
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:player_move, "invalid field value"),
                      __STACKTRACE__
          end
        end
      ]

      defp encode_unknown_fields(acc, msg) do
        Enum.reduce(msg.__struct__.unknown_fields(msg), acc, fn {tag, wire_type, bytes}, acc ->
          case wire_type do
            0 ->
              [acc, Protox.Encode.make_key_bytes(tag, :int32), bytes]

            1 ->
              [acc, Protox.Encode.make_key_bytes(tag, :double), bytes]

            2 ->
              len_bytes = bytes |> byte_size() |> Protox.Varint.encode()
              [acc, Protox.Encode.make_key_bytes(tag, :packed), len_bytes, bytes]

            5 ->
              [acc, Protox.Encode.make_key_bytes(tag, :float), bytes]
          end
        end)
      end
    )

    (
      (
        @spec decode(binary) :: {:ok, struct} | {:error, any}
        def decode(bytes) do
          try do
            {:ok, decode!(bytes)}
          rescue
            e in [Protox.DecodingError, Protox.IllegalTagError, Protox.RequiredFieldsError] ->
              {:error, e}
          end
        end

        (
          @spec decode!(binary) :: struct | no_return
          def decode!(bytes) do
            parse_key_value(bytes, struct(Reply.Result))
          end
        )
      )

      (
        @spec parse_key_value(binary, struct) :: struct
        defp parse_key_value(<<>>, msg) do
          msg
        end

        defp parse_key_value(bytes, msg) do
          {field, rest} =
            case Protox.Decode.parse_key(bytes) do
              {0, _, _} ->
                raise %Protox.IllegalTagError{}

              {1, _, bytes} ->
                {value, rest} = Protox.Decode.parse_int64(bytes)
                {[packet_id: value], rest}

              {2, _, bytes} ->
                {value, rest} = Protox.Decode.parse_enum(bytes, Reply.StatusCode)
                {[status_code: value], rest}

              {3, _, bytes} ->
                {len, bytes} = Protox.Varint.decode(bytes)
                {delimited, rest} = Protox.Decode.parse_delimited(bytes, len)

                {[
                   case msg.payload do
                     {:enter_scene, previous_value} ->
                       {:payload,
                        {:enter_scene,
                         Protox.MergeMessage.merge(
                           previous_value,
                           Reply.EnterScene.decode!(delimited)
                         )}}

                     _ ->
                       {:payload, {:enter_scene, Reply.EnterScene.decode!(delimited)}}
                   end
                 ], rest}

              {4, _, bytes} ->
                {len, bytes} = Protox.Varint.decode(bytes)
                {delimited, rest} = Protox.Decode.parse_delimited(bytes, len)

                {[
                   case msg.payload do
                     {:player_move, previous_value} ->
                       {:payload,
                        {:player_move,
                         Protox.MergeMessage.merge(
                           previous_value,
                           Reply.PlayerMove.decode!(delimited)
                         )}}

                     _ ->
                       {:payload, {:player_move, Reply.PlayerMove.decode!(delimited)}}
                   end
                 ], rest}

              {tag, wire_type, rest} ->
                {value, rest} = Protox.Decode.parse_unknown(tag, wire_type, rest)

                {[
                   {msg.__struct__.unknown_fields_name,
                    [value | msg.__struct__.unknown_fields(msg)]}
                 ], rest}
            end

          msg_updated = struct(msg, field)
          parse_key_value(rest, msg_updated)
        end
      )

      []
    )

    (
      @spec json_decode(iodata(), keyword()) :: {:ok, struct()} | {:error, any()}
      def json_decode(input, opts \\ []) do
        try do
          {:ok, json_decode!(input, opts)}
        rescue
          e in Protox.JsonDecodingError -> {:error, e}
        end
      end

      @spec json_decode!(iodata(), keyword()) :: struct() | no_return()
      def json_decode!(input, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :decode)

        Protox.JsonDecode.decode!(
          input,
          Reply.Result,
          &json_library_wrapper.decode!(json_library, &1)
        )
      end

      @spec json_encode(struct(), keyword()) :: {:ok, iodata()} | {:error, any()}
      def json_encode(msg, opts \\ []) do
        try do
          {:ok, json_encode!(msg, opts)}
        rescue
          e in Protox.JsonEncodingError -> {:error, e}
        end
      end

      @spec json_encode!(struct(), keyword()) :: iodata() | no_return()
      def json_encode!(msg, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :encode)
        Protox.JsonEncode.encode!(msg, &json_library_wrapper.encode!(json_library, &1))
      end
    )

    (
      @deprecated "Use fields_defs()/0 instead"
      @spec defs() :: %{
              required(non_neg_integer) => {atom, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs() do
        %{
          1 => {:packet_id, {:scalar, 0}, :int64},
          2 => {:status_code, {:scalar, :ok}, {:enum, Reply.StatusCode}},
          3 => {:enter_scene, {:oneof, :payload}, {:message, Reply.EnterScene}},
          4 => {:player_move, {:oneof, :payload}, {:message, Reply.PlayerMove}}
        }
      end

      @deprecated "Use fields_defs()/0 instead"
      @spec defs_by_name() :: %{
              required(atom) => {non_neg_integer, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs_by_name() do
        %{
          enter_scene: {3, {:oneof, :payload}, {:message, Reply.EnterScene}},
          packet_id: {1, {:scalar, 0}, :int64},
          player_move: {4, {:oneof, :payload}, {:message, Reply.PlayerMove}},
          status_code: {2, {:scalar, :ok}, {:enum, Reply.StatusCode}}
        }
      end
    )

    (
      @spec fields_defs() :: list(Protox.Field.t())
      def fields_defs() do
        [
          %{
            __struct__: Protox.Field,
            json_name: "packetId",
            kind: {:scalar, 0},
            label: :optional,
            name: :packet_id,
            tag: 1,
            type: :int64
          },
          %{
            __struct__: Protox.Field,
            json_name: "statusCode",
            kind: {:scalar, :ok},
            label: :optional,
            name: :status_code,
            tag: 2,
            type: {:enum, Reply.StatusCode}
          },
          %{
            __struct__: Protox.Field,
            json_name: "enterScene",
            kind: {:oneof, :payload},
            label: :optional,
            name: :enter_scene,
            tag: 3,
            type: {:message, Reply.EnterScene}
          },
          %{
            __struct__: Protox.Field,
            json_name: "playerMove",
            kind: {:oneof, :payload},
            label: :optional,
            name: :player_move,
            tag: 4,
            type: {:message, Reply.PlayerMove}
          }
        ]
      end

      [
        @spec(field_def(atom) :: {:ok, Protox.Field.t()} | {:error, :no_such_field}),
        (
          def field_def(:packet_id) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "packetId",
               kind: {:scalar, 0},
               label: :optional,
               name: :packet_id,
               tag: 1,
               type: :int64
             }}
          end

          def field_def("packetId") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "packetId",
               kind: {:scalar, 0},
               label: :optional,
               name: :packet_id,
               tag: 1,
               type: :int64
             }}
          end

          def field_def("packet_id") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "packetId",
               kind: {:scalar, 0},
               label: :optional,
               name: :packet_id,
               tag: 1,
               type: :int64
             }}
          end
        ),
        (
          def field_def(:status_code) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "statusCode",
               kind: {:scalar, :ok},
               label: :optional,
               name: :status_code,
               tag: 2,
               type: {:enum, Reply.StatusCode}
             }}
          end

          def field_def("statusCode") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "statusCode",
               kind: {:scalar, :ok},
               label: :optional,
               name: :status_code,
               tag: 2,
               type: {:enum, Reply.StatusCode}
             }}
          end

          def field_def("status_code") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "statusCode",
               kind: {:scalar, :ok},
               label: :optional,
               name: :status_code,
               tag: 2,
               type: {:enum, Reply.StatusCode}
             }}
          end
        ),
        (
          def field_def(:enter_scene) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "enterScene",
               kind: {:oneof, :payload},
               label: :optional,
               name: :enter_scene,
               tag: 3,
               type: {:message, Reply.EnterScene}
             }}
          end

          def field_def("enterScene") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "enterScene",
               kind: {:oneof, :payload},
               label: :optional,
               name: :enter_scene,
               tag: 3,
               type: {:message, Reply.EnterScene}
             }}
          end

          def field_def("enter_scene") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "enterScene",
               kind: {:oneof, :payload},
               label: :optional,
               name: :enter_scene,
               tag: 3,
               type: {:message, Reply.EnterScene}
             }}
          end
        ),
        (
          def field_def(:player_move) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "playerMove",
               kind: {:oneof, :payload},
               label: :optional,
               name: :player_move,
               tag: 4,
               type: {:message, Reply.PlayerMove}
             }}
          end

          def field_def("playerMove") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "playerMove",
               kind: {:oneof, :payload},
               label: :optional,
               name: :player_move,
               tag: 4,
               type: {:message, Reply.PlayerMove}
             }}
          end

          def field_def("player_move") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "playerMove",
               kind: {:oneof, :payload},
               label: :optional,
               name: :player_move,
               tag: 4,
               type: {:message, Reply.PlayerMove}
             }}
          end
        ),
        def field_def(_) do
          {:error, :no_such_field}
        end
      ]
    )

    (
      @spec unknown_fields(struct) :: [{non_neg_integer, Protox.Types.tag(), binary}]
      def unknown_fields(msg) do
        msg.__uf__
      end

      @spec unknown_fields_name() :: :__uf__
      def unknown_fields_name() do
        :__uf__
      end

      @spec clear_unknown_fields(struct) :: struct
      def clear_unknown_fields(msg) do
        struct!(msg, [{unknown_fields_name(), []}])
      end
    )

    (
      @spec required_fields() :: []
      def required_fields() do
        []
      end
    )

    (
      @spec syntax() :: atom()
      def syntax() do
        :proto3
      end
    )

    [
      @spec(default(atom) :: {:ok, boolean | integer | String.t() | float} | {:error, atom}),
      def default(:packet_id) do
        {:ok, 0}
      end,
      def default(:status_code) do
        {:ok, :ok}
      end,
      def default(:enter_scene) do
        {:error, :no_default_value}
      end,
      def default(:player_move) do
        {:error, :no_default_value}
      end,
      def default(_) do
        {:error, :no_such_field}
      end
    ]

    (
      @spec file_options() :: nil
      def file_options() do
        nil
      end
    )
  end,
  defmodule ServerResponse do
    @moduledoc false
    defstruct status: :OK, payload: nil, __uf__: []

    (
      (
        @spec encode(struct) :: {:ok, iodata} | {:error, any}
        def encode(msg) do
          try do
            {:ok, encode!(msg)}
          rescue
            e in [Protox.EncodingError, Protox.RequiredFieldsError] -> {:error, e}
          end
        end

        @spec encode!(struct) :: iodata | no_return
        def encode!(msg) do
          [] |> encode_payload(msg) |> encode_status(msg) |> encode_unknown_fields(msg)
        end
      )

      [
        defp encode_payload(acc, msg) do
          case msg.payload do
            nil -> acc
            {:message, _field_value} -> encode_message(acc, msg)
          end
        end
      ]

      [
        defp encode_status(acc, msg) do
          try do
            if msg.status == :OK do
              acc
            else
              [
                acc,
                "\b",
                msg.status |> ServerResponse.Status.encode() |> Protox.Encode.encode_enum()
              ]
            end
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:status, "invalid field value"), __STACKTRACE__
          end
        end,
        defp encode_message(acc, msg) do
          try do
            {_, child_field_value} = msg.payload
            [acc, "\"", Protox.Encode.encode_string(child_field_value)]
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:message, "invalid field value"), __STACKTRACE__
          end
        end
      ]

      defp encode_unknown_fields(acc, msg) do
        Enum.reduce(msg.__struct__.unknown_fields(msg), acc, fn {tag, wire_type, bytes}, acc ->
          case wire_type do
            0 ->
              [acc, Protox.Encode.make_key_bytes(tag, :int32), bytes]

            1 ->
              [acc, Protox.Encode.make_key_bytes(tag, :double), bytes]

            2 ->
              len_bytes = bytes |> byte_size() |> Protox.Varint.encode()
              [acc, Protox.Encode.make_key_bytes(tag, :packed), len_bytes, bytes]

            5 ->
              [acc, Protox.Encode.make_key_bytes(tag, :float), bytes]
          end
        end)
      end
    )

    (
      (
        @spec decode(binary) :: {:ok, struct} | {:error, any}
        def decode(bytes) do
          try do
            {:ok, decode!(bytes)}
          rescue
            e in [Protox.DecodingError, Protox.IllegalTagError, Protox.RequiredFieldsError] ->
              {:error, e}
          end
        end

        (
          @spec decode!(binary) :: struct | no_return
          def decode!(bytes) do
            parse_key_value(bytes, struct(ServerResponse))
          end
        )
      )

      (
        @spec parse_key_value(binary, struct) :: struct
        defp parse_key_value(<<>>, msg) do
          msg
        end

        defp parse_key_value(bytes, msg) do
          {field, rest} =
            case Protox.Decode.parse_key(bytes) do
              {0, _, _} ->
                raise %Protox.IllegalTagError{}

              {1, _, bytes} ->
                {value, rest} = Protox.Decode.parse_enum(bytes, ServerResponse.Status)
                {[status: value], rest}

              {4, _, bytes} ->
                {len, bytes} = Protox.Varint.decode(bytes)
                {delimited, rest} = Protox.Decode.parse_delimited(bytes, len)
                {[payload: {:message, delimited}], rest}

              {tag, wire_type, rest} ->
                {value, rest} = Protox.Decode.parse_unknown(tag, wire_type, rest)

                {[
                   {msg.__struct__.unknown_fields_name,
                    [value | msg.__struct__.unknown_fields(msg)]}
                 ], rest}
            end

          msg_updated = struct(msg, field)
          parse_key_value(rest, msg_updated)
        end
      )

      []
    )

    (
      @spec json_decode(iodata(), keyword()) :: {:ok, struct()} | {:error, any()}
      def json_decode(input, opts \\ []) do
        try do
          {:ok, json_decode!(input, opts)}
        rescue
          e in Protox.JsonDecodingError -> {:error, e}
        end
      end

      @spec json_decode!(iodata(), keyword()) :: struct() | no_return()
      def json_decode!(input, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :decode)

        Protox.JsonDecode.decode!(
          input,
          ServerResponse,
          &json_library_wrapper.decode!(json_library, &1)
        )
      end

      @spec json_encode(struct(), keyword()) :: {:ok, iodata()} | {:error, any()}
      def json_encode(msg, opts \\ []) do
        try do
          {:ok, json_encode!(msg, opts)}
        rescue
          e in Protox.JsonEncodingError -> {:error, e}
        end
      end

      @spec json_encode!(struct(), keyword()) :: iodata() | no_return()
      def json_encode!(msg, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :encode)
        Protox.JsonEncode.encode!(msg, &json_library_wrapper.encode!(json_library, &1))
      end
    )

    (
      @deprecated "Use fields_defs()/0 instead"
      @spec defs() :: %{
              required(non_neg_integer) => {atom, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs() do
        %{
          1 => {:status, {:scalar, :OK}, {:enum, ServerResponse.Status}},
          4 => {:message, {:oneof, :payload}, :string}
        }
      end

      @deprecated "Use fields_defs()/0 instead"
      @spec defs_by_name() :: %{
              required(atom) => {non_neg_integer, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs_by_name() do
        %{
          message: {4, {:oneof, :payload}, :string},
          status: {1, {:scalar, :OK}, {:enum, ServerResponse.Status}}
        }
      end
    )

    (
      @spec fields_defs() :: list(Protox.Field.t())
      def fields_defs() do
        [
          %{
            __struct__: Protox.Field,
            json_name: "status",
            kind: {:scalar, :OK},
            label: :optional,
            name: :status,
            tag: 1,
            type: {:enum, ServerResponse.Status}
          },
          %{
            __struct__: Protox.Field,
            json_name: "message",
            kind: {:oneof, :payload},
            label: :optional,
            name: :message,
            tag: 4,
            type: :string
          }
        ]
      end

      [
        @spec(field_def(atom) :: {:ok, Protox.Field.t()} | {:error, :no_such_field}),
        (
          def field_def(:status) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "status",
               kind: {:scalar, :OK},
               label: :optional,
               name: :status,
               tag: 1,
               type: {:enum, ServerResponse.Status}
             }}
          end

          def field_def("status") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "status",
               kind: {:scalar, :OK},
               label: :optional,
               name: :status,
               tag: 1,
               type: {:enum, ServerResponse.Status}
             }}
          end

          []
        ),
        (
          def field_def(:message) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "message",
               kind: {:oneof, :payload},
               label: :optional,
               name: :message,
               tag: 4,
               type: :string
             }}
          end

          def field_def("message") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "message",
               kind: {:oneof, :payload},
               label: :optional,
               name: :message,
               tag: 4,
               type: :string
             }}
          end

          []
        ),
        def field_def(_) do
          {:error, :no_such_field}
        end
      ]
    )

    (
      @spec unknown_fields(struct) :: [{non_neg_integer, Protox.Types.tag(), binary}]
      def unknown_fields(msg) do
        msg.__uf__
      end

      @spec unknown_fields_name() :: :__uf__
      def unknown_fields_name() do
        :__uf__
      end

      @spec clear_unknown_fields(struct) :: struct
      def clear_unknown_fields(msg) do
        struct!(msg, [{unknown_fields_name(), []}])
      end
    )

    (
      @spec required_fields() :: []
      def required_fields() do
        []
      end
    )

    (
      @spec syntax() :: atom()
      def syntax() do
        :proto3
      end
    )

    [
      @spec(default(atom) :: {:ok, boolean | integer | String.t() | float} | {:error, atom}),
      def default(:status) do
        {:ok, :OK}
      end,
      def default(:message) do
        {:error, :no_default_value}
      end,
      def default(_) do
        {:error, :no_such_field}
      end
    ]

    (
      @spec file_options() :: nil
      def file_options() do
        nil
      end
    )
  end,
  defmodule TimeSync do
    @moduledoc false
    defstruct __uf__: []

    (
      (
        @spec encode(struct) :: {:ok, iodata} | {:error, any}
        def encode(msg) do
          try do
            {:ok, encode!(msg)}
          rescue
            e in [Protox.EncodingError, Protox.RequiredFieldsError] -> {:error, e}
          end
        end

        @spec encode!(struct) :: iodata | no_return
        def encode!(msg) do
          [] |> encode_unknown_fields(msg)
        end
      )

      []
      []

      defp encode_unknown_fields(acc, msg) do
        Enum.reduce(msg.__struct__.unknown_fields(msg), acc, fn {tag, wire_type, bytes}, acc ->
          case wire_type do
            0 ->
              [acc, Protox.Encode.make_key_bytes(tag, :int32), bytes]

            1 ->
              [acc, Protox.Encode.make_key_bytes(tag, :double), bytes]

            2 ->
              len_bytes = bytes |> byte_size() |> Protox.Varint.encode()
              [acc, Protox.Encode.make_key_bytes(tag, :packed), len_bytes, bytes]

            5 ->
              [acc, Protox.Encode.make_key_bytes(tag, :float), bytes]
          end
        end)
      end
    )

    (
      (
        @spec decode(binary) :: {:ok, struct} | {:error, any}
        def decode(bytes) do
          try do
            {:ok, decode!(bytes)}
          rescue
            e in [Protox.DecodingError, Protox.IllegalTagError, Protox.RequiredFieldsError] ->
              {:error, e}
          end
        end

        (
          @spec decode!(binary) :: struct | no_return
          def decode!(bytes) do
            parse_key_value(bytes, struct(TimeSync))
          end
        )
      )

      (
        @spec parse_key_value(binary, struct) :: struct
        defp parse_key_value(<<>>, msg) do
          msg
        end

        defp parse_key_value(bytes, msg) do
          {field, rest} =
            case Protox.Decode.parse_key(bytes) do
              {0, _, _} ->
                raise %Protox.IllegalTagError{}

              {tag, wire_type, rest} ->
                {value, rest} = Protox.Decode.parse_unknown(tag, wire_type, rest)

                {[
                   {msg.__struct__.unknown_fields_name,
                    [value | msg.__struct__.unknown_fields(msg)]}
                 ], rest}
            end

          msg_updated = struct(msg, field)
          parse_key_value(rest, msg_updated)
        end
      )

      []
    )

    (
      @spec json_decode(iodata(), keyword()) :: {:ok, struct()} | {:error, any()}
      def json_decode(input, opts \\ []) do
        try do
          {:ok, json_decode!(input, opts)}
        rescue
          e in Protox.JsonDecodingError -> {:error, e}
        end
      end

      @spec json_decode!(iodata(), keyword()) :: struct() | no_return()
      def json_decode!(input, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :decode)

        Protox.JsonDecode.decode!(
          input,
          TimeSync,
          &json_library_wrapper.decode!(json_library, &1)
        )
      end

      @spec json_encode(struct(), keyword()) :: {:ok, iodata()} | {:error, any()}
      def json_encode(msg, opts \\ []) do
        try do
          {:ok, json_encode!(msg, opts)}
        rescue
          e in Protox.JsonEncodingError -> {:error, e}
        end
      end

      @spec json_encode!(struct(), keyword()) :: iodata() | no_return()
      def json_encode!(msg, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :encode)
        Protox.JsonEncode.encode!(msg, &json_library_wrapper.encode!(json_library, &1))
      end
    )

    (
      @deprecated "Use fields_defs()/0 instead"
      @spec defs() :: %{
              required(non_neg_integer) => {atom, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs() do
        %{}
      end

      @deprecated "Use fields_defs()/0 instead"
      @spec defs_by_name() :: %{
              required(atom) => {non_neg_integer, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs_by_name() do
        %{}
      end
    )

    (
      @spec fields_defs() :: list(Protox.Field.t())
      def fields_defs() do
        []
      end

      [
        @spec(field_def(atom) :: {:ok, Protox.Field.t()} | {:error, :no_such_field}),
        def field_def(_) do
          {:error, :no_such_field}
        end
      ]
    )

    (
      @spec unknown_fields(struct) :: [{non_neg_integer, Protox.Types.tag(), binary}]
      def unknown_fields(msg) do
        msg.__uf__
      end

      @spec unknown_fields_name() :: :__uf__
      def unknown_fields_name() do
        :__uf__
      end

      @spec clear_unknown_fields(struct) :: struct
      def clear_unknown_fields(msg) do
        struct!(msg, [{unknown_fields_name(), []}])
      end
    )

    (
      @spec required_fields() :: []
      def required_fields() do
        []
      end
    )

    (
      @spec syntax() :: atom()
      def syntax() do
        :proto3
      end
    )

    [
      @spec(default(atom) :: {:ok, boolean | integer | String.t() | float} | {:error, atom}),
      def default(_) do
        {:error, :no_such_field}
      end
    ]

    (
      @spec file_options() :: nil
      def file_options() do
        nil
      end
    )
  end,
  defmodule Types.Movement do
    @moduledoc false
    defstruct location: nil, velocity: nil, acceleration: nil, __uf__: []

    (
      (
        @spec encode(struct) :: {:ok, iodata} | {:error, any}
        def encode(msg) do
          try do
            {:ok, encode!(msg)}
          rescue
            e in [Protox.EncodingError, Protox.RequiredFieldsError] -> {:error, e}
          end
        end

        @spec encode!(struct) :: iodata | no_return
        def encode!(msg) do
          []
          |> encode_location(msg)
          |> encode_velocity(msg)
          |> encode_acceleration(msg)
          |> encode_unknown_fields(msg)
        end
      )

      []

      [
        defp encode_location(acc, msg) do
          try do
            if msg.location == nil do
              acc
            else
              [acc, "\n", Protox.Encode.encode_message(msg.location)]
            end
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:location, "invalid field value"), __STACKTRACE__
          end
        end,
        defp encode_velocity(acc, msg) do
          try do
            if msg.velocity == nil do
              acc
            else
              [acc, "\x12", Protox.Encode.encode_message(msg.velocity)]
            end
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:velocity, "invalid field value"), __STACKTRACE__
          end
        end,
        defp encode_acceleration(acc, msg) do
          try do
            if msg.acceleration == nil do
              acc
            else
              [acc, "\x1A", Protox.Encode.encode_message(msg.acceleration)]
            end
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:acceleration, "invalid field value"),
                      __STACKTRACE__
          end
        end
      ]

      defp encode_unknown_fields(acc, msg) do
        Enum.reduce(msg.__struct__.unknown_fields(msg), acc, fn {tag, wire_type, bytes}, acc ->
          case wire_type do
            0 ->
              [acc, Protox.Encode.make_key_bytes(tag, :int32), bytes]

            1 ->
              [acc, Protox.Encode.make_key_bytes(tag, :double), bytes]

            2 ->
              len_bytes = bytes |> byte_size() |> Protox.Varint.encode()
              [acc, Protox.Encode.make_key_bytes(tag, :packed), len_bytes, bytes]

            5 ->
              [acc, Protox.Encode.make_key_bytes(tag, :float), bytes]
          end
        end)
      end
    )

    (
      (
        @spec decode(binary) :: {:ok, struct} | {:error, any}
        def decode(bytes) do
          try do
            {:ok, decode!(bytes)}
          rescue
            e in [Protox.DecodingError, Protox.IllegalTagError, Protox.RequiredFieldsError] ->
              {:error, e}
          end
        end

        (
          @spec decode!(binary) :: struct | no_return
          def decode!(bytes) do
            parse_key_value(bytes, struct(Types.Movement))
          end
        )
      )

      (
        @spec parse_key_value(binary, struct) :: struct
        defp parse_key_value(<<>>, msg) do
          msg
        end

        defp parse_key_value(bytes, msg) do
          {field, rest} =
            case Protox.Decode.parse_key(bytes) do
              {0, _, _} ->
                raise %Protox.IllegalTagError{}

              {1, _, bytes} ->
                {len, bytes} = Protox.Varint.decode(bytes)
                {delimited, rest} = Protox.Decode.parse_delimited(bytes, len)

                {[
                   location:
                     Protox.MergeMessage.merge(msg.location, Types.Vector.decode!(delimited))
                 ], rest}

              {2, _, bytes} ->
                {len, bytes} = Protox.Varint.decode(bytes)
                {delimited, rest} = Protox.Decode.parse_delimited(bytes, len)

                {[
                   velocity:
                     Protox.MergeMessage.merge(msg.velocity, Types.Vector.decode!(delimited))
                 ], rest}

              {3, _, bytes} ->
                {len, bytes} = Protox.Varint.decode(bytes)
                {delimited, rest} = Protox.Decode.parse_delimited(bytes, len)

                {[
                   acceleration:
                     Protox.MergeMessage.merge(msg.acceleration, Types.Vector.decode!(delimited))
                 ], rest}

              {tag, wire_type, rest} ->
                {value, rest} = Protox.Decode.parse_unknown(tag, wire_type, rest)

                {[
                   {msg.__struct__.unknown_fields_name,
                    [value | msg.__struct__.unknown_fields(msg)]}
                 ], rest}
            end

          msg_updated = struct(msg, field)
          parse_key_value(rest, msg_updated)
        end
      )

      []
    )

    (
      @spec json_decode(iodata(), keyword()) :: {:ok, struct()} | {:error, any()}
      def json_decode(input, opts \\ []) do
        try do
          {:ok, json_decode!(input, opts)}
        rescue
          e in Protox.JsonDecodingError -> {:error, e}
        end
      end

      @spec json_decode!(iodata(), keyword()) :: struct() | no_return()
      def json_decode!(input, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :decode)

        Protox.JsonDecode.decode!(
          input,
          Types.Movement,
          &json_library_wrapper.decode!(json_library, &1)
        )
      end

      @spec json_encode(struct(), keyword()) :: {:ok, iodata()} | {:error, any()}
      def json_encode(msg, opts \\ []) do
        try do
          {:ok, json_encode!(msg, opts)}
        rescue
          e in Protox.JsonEncodingError -> {:error, e}
        end
      end

      @spec json_encode!(struct(), keyword()) :: iodata() | no_return()
      def json_encode!(msg, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :encode)
        Protox.JsonEncode.encode!(msg, &json_library_wrapper.encode!(json_library, &1))
      end
    )

    (
      @deprecated "Use fields_defs()/0 instead"
      @spec defs() :: %{
              required(non_neg_integer) => {atom, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs() do
        %{
          1 => {:location, {:scalar, nil}, {:message, Types.Vector}},
          2 => {:velocity, {:scalar, nil}, {:message, Types.Vector}},
          3 => {:acceleration, {:scalar, nil}, {:message, Types.Vector}}
        }
      end

      @deprecated "Use fields_defs()/0 instead"
      @spec defs_by_name() :: %{
              required(atom) => {non_neg_integer, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs_by_name() do
        %{
          acceleration: {3, {:scalar, nil}, {:message, Types.Vector}},
          location: {1, {:scalar, nil}, {:message, Types.Vector}},
          velocity: {2, {:scalar, nil}, {:message, Types.Vector}}
        }
      end
    )

    (
      @spec fields_defs() :: list(Protox.Field.t())
      def fields_defs() do
        [
          %{
            __struct__: Protox.Field,
            json_name: "location",
            kind: {:scalar, nil},
            label: :optional,
            name: :location,
            tag: 1,
            type: {:message, Types.Vector}
          },
          %{
            __struct__: Protox.Field,
            json_name: "velocity",
            kind: {:scalar, nil},
            label: :optional,
            name: :velocity,
            tag: 2,
            type: {:message, Types.Vector}
          },
          %{
            __struct__: Protox.Field,
            json_name: "acceleration",
            kind: {:scalar, nil},
            label: :optional,
            name: :acceleration,
            tag: 3,
            type: {:message, Types.Vector}
          }
        ]
      end

      [
        @spec(field_def(atom) :: {:ok, Protox.Field.t()} | {:error, :no_such_field}),
        (
          def field_def(:location) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "location",
               kind: {:scalar, nil},
               label: :optional,
               name: :location,
               tag: 1,
               type: {:message, Types.Vector}
             }}
          end

          def field_def("location") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "location",
               kind: {:scalar, nil},
               label: :optional,
               name: :location,
               tag: 1,
               type: {:message, Types.Vector}
             }}
          end

          []
        ),
        (
          def field_def(:velocity) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "velocity",
               kind: {:scalar, nil},
               label: :optional,
               name: :velocity,
               tag: 2,
               type: {:message, Types.Vector}
             }}
          end

          def field_def("velocity") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "velocity",
               kind: {:scalar, nil},
               label: :optional,
               name: :velocity,
               tag: 2,
               type: {:message, Types.Vector}
             }}
          end

          []
        ),
        (
          def field_def(:acceleration) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "acceleration",
               kind: {:scalar, nil},
               label: :optional,
               name: :acceleration,
               tag: 3,
               type: {:message, Types.Vector}
             }}
          end

          def field_def("acceleration") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "acceleration",
               kind: {:scalar, nil},
               label: :optional,
               name: :acceleration,
               tag: 3,
               type: {:message, Types.Vector}
             }}
          end

          []
        ),
        def field_def(_) do
          {:error, :no_such_field}
        end
      ]
    )

    (
      @spec unknown_fields(struct) :: [{non_neg_integer, Protox.Types.tag(), binary}]
      def unknown_fields(msg) do
        msg.__uf__
      end

      @spec unknown_fields_name() :: :__uf__
      def unknown_fields_name() do
        :__uf__
      end

      @spec clear_unknown_fields(struct) :: struct
      def clear_unknown_fields(msg) do
        struct!(msg, [{unknown_fields_name(), []}])
      end
    )

    (
      @spec required_fields() :: []
      def required_fields() do
        []
      end
    )

    (
      @spec syntax() :: atom()
      def syntax() do
        :proto3
      end
    )

    [
      @spec(default(atom) :: {:ok, boolean | integer | String.t() | float} | {:error, atom}),
      def default(:location) do
        {:ok, nil}
      end,
      def default(:velocity) do
        {:ok, nil}
      end,
      def default(:acceleration) do
        {:ok, nil}
      end,
      def default(_) do
        {:error, :no_such_field}
      end
    ]

    (
      @spec file_options() :: nil
      def file_options() do
        nil
      end
    )
  end,
  defmodule Types.Vector do
    @moduledoc false
    defstruct x: 0.0, y: 0.0, z: 0.0, __uf__: []

    (
      (
        @spec encode(struct) :: {:ok, iodata} | {:error, any}
        def encode(msg) do
          try do
            {:ok, encode!(msg)}
          rescue
            e in [Protox.EncodingError, Protox.RequiredFieldsError] -> {:error, e}
          end
        end

        @spec encode!(struct) :: iodata | no_return
        def encode!(msg) do
          [] |> encode_x(msg) |> encode_y(msg) |> encode_z(msg) |> encode_unknown_fields(msg)
        end
      )

      []

      [
        defp encode_x(acc, msg) do
          try do
            if msg.x == 0.0 do
              acc
            else
              [acc, "\r", Protox.Encode.encode_float(msg.x)]
            end
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:x, "invalid field value"), __STACKTRACE__
          end
        end,
        defp encode_y(acc, msg) do
          try do
            if msg.y == 0.0 do
              acc
            else
              [acc, "\x15", Protox.Encode.encode_float(msg.y)]
            end
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:y, "invalid field value"), __STACKTRACE__
          end
        end,
        defp encode_z(acc, msg) do
          try do
            if msg.z == 0.0 do
              acc
            else
              [acc, "\x1D", Protox.Encode.encode_float(msg.z)]
            end
          rescue
            ArgumentError ->
              reraise Protox.EncodingError.new(:z, "invalid field value"), __STACKTRACE__
          end
        end
      ]

      defp encode_unknown_fields(acc, msg) do
        Enum.reduce(msg.__struct__.unknown_fields(msg), acc, fn {tag, wire_type, bytes}, acc ->
          case wire_type do
            0 ->
              [acc, Protox.Encode.make_key_bytes(tag, :int32), bytes]

            1 ->
              [acc, Protox.Encode.make_key_bytes(tag, :double), bytes]

            2 ->
              len_bytes = bytes |> byte_size() |> Protox.Varint.encode()
              [acc, Protox.Encode.make_key_bytes(tag, :packed), len_bytes, bytes]

            5 ->
              [acc, Protox.Encode.make_key_bytes(tag, :float), bytes]
          end
        end)
      end
    )

    (
      (
        @spec decode(binary) :: {:ok, struct} | {:error, any}
        def decode(bytes) do
          try do
            {:ok, decode!(bytes)}
          rescue
            e in [Protox.DecodingError, Protox.IllegalTagError, Protox.RequiredFieldsError] ->
              {:error, e}
          end
        end

        (
          @spec decode!(binary) :: struct | no_return
          def decode!(bytes) do
            parse_key_value(bytes, struct(Types.Vector))
          end
        )
      )

      (
        @spec parse_key_value(binary, struct) :: struct
        defp parse_key_value(<<>>, msg) do
          msg
        end

        defp parse_key_value(bytes, msg) do
          {field, rest} =
            case Protox.Decode.parse_key(bytes) do
              {0, _, _} ->
                raise %Protox.IllegalTagError{}

              {1, _, bytes} ->
                {value, rest} = Protox.Decode.parse_float(bytes)
                {[x: value], rest}

              {2, _, bytes} ->
                {value, rest} = Protox.Decode.parse_float(bytes)
                {[y: value], rest}

              {3, _, bytes} ->
                {value, rest} = Protox.Decode.parse_float(bytes)
                {[z: value], rest}

              {tag, wire_type, rest} ->
                {value, rest} = Protox.Decode.parse_unknown(tag, wire_type, rest)

                {[
                   {msg.__struct__.unknown_fields_name,
                    [value | msg.__struct__.unknown_fields(msg)]}
                 ], rest}
            end

          msg_updated = struct(msg, field)
          parse_key_value(rest, msg_updated)
        end
      )

      []
    )

    (
      @spec json_decode(iodata(), keyword()) :: {:ok, struct()} | {:error, any()}
      def json_decode(input, opts \\ []) do
        try do
          {:ok, json_decode!(input, opts)}
        rescue
          e in Protox.JsonDecodingError -> {:error, e}
        end
      end

      @spec json_decode!(iodata(), keyword()) :: struct() | no_return()
      def json_decode!(input, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :decode)

        Protox.JsonDecode.decode!(
          input,
          Types.Vector,
          &json_library_wrapper.decode!(json_library, &1)
        )
      end

      @spec json_encode(struct(), keyword()) :: {:ok, iodata()} | {:error, any()}
      def json_encode(msg, opts \\ []) do
        try do
          {:ok, json_encode!(msg, opts)}
        rescue
          e in Protox.JsonEncodingError -> {:error, e}
        end
      end

      @spec json_encode!(struct(), keyword()) :: iodata() | no_return()
      def json_encode!(msg, opts \\ []) do
        {json_library_wrapper, json_library} = Protox.JsonLibrary.get_library(opts, :encode)
        Protox.JsonEncode.encode!(msg, &json_library_wrapper.encode!(json_library, &1))
      end
    )

    (
      @deprecated "Use fields_defs()/0 instead"
      @spec defs() :: %{
              required(non_neg_integer) => {atom, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs() do
        %{
          1 => {:x, {:scalar, 0.0}, :float},
          2 => {:y, {:scalar, 0.0}, :float},
          3 => {:z, {:scalar, 0.0}, :float}
        }
      end

      @deprecated "Use fields_defs()/0 instead"
      @spec defs_by_name() :: %{
              required(atom) => {non_neg_integer, Protox.Types.kind(), Protox.Types.type()}
            }
      def defs_by_name() do
        %{
          x: {1, {:scalar, 0.0}, :float},
          y: {2, {:scalar, 0.0}, :float},
          z: {3, {:scalar, 0.0}, :float}
        }
      end
    )

    (
      @spec fields_defs() :: list(Protox.Field.t())
      def fields_defs() do
        [
          %{
            __struct__: Protox.Field,
            json_name: "x",
            kind: {:scalar, 0.0},
            label: :optional,
            name: :x,
            tag: 1,
            type: :float
          },
          %{
            __struct__: Protox.Field,
            json_name: "y",
            kind: {:scalar, 0.0},
            label: :optional,
            name: :y,
            tag: 2,
            type: :float
          },
          %{
            __struct__: Protox.Field,
            json_name: "z",
            kind: {:scalar, 0.0},
            label: :optional,
            name: :z,
            tag: 3,
            type: :float
          }
        ]
      end

      [
        @spec(field_def(atom) :: {:ok, Protox.Field.t()} | {:error, :no_such_field}),
        (
          def field_def(:x) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "x",
               kind: {:scalar, 0.0},
               label: :optional,
               name: :x,
               tag: 1,
               type: :float
             }}
          end

          def field_def("x") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "x",
               kind: {:scalar, 0.0},
               label: :optional,
               name: :x,
               tag: 1,
               type: :float
             }}
          end

          []
        ),
        (
          def field_def(:y) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "y",
               kind: {:scalar, 0.0},
               label: :optional,
               name: :y,
               tag: 2,
               type: :float
             }}
          end

          def field_def("y") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "y",
               kind: {:scalar, 0.0},
               label: :optional,
               name: :y,
               tag: 2,
               type: :float
             }}
          end

          []
        ),
        (
          def field_def(:z) do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "z",
               kind: {:scalar, 0.0},
               label: :optional,
               name: :z,
               tag: 3,
               type: :float
             }}
          end

          def field_def("z") do
            {:ok,
             %{
               __struct__: Protox.Field,
               json_name: "z",
               kind: {:scalar, 0.0},
               label: :optional,
               name: :z,
               tag: 3,
               type: :float
             }}
          end

          []
        ),
        def field_def(_) do
          {:error, :no_such_field}
        end
      ]
    )

    (
      @spec unknown_fields(struct) :: [{non_neg_integer, Protox.Types.tag(), binary}]
      def unknown_fields(msg) do
        msg.__uf__
      end

      @spec unknown_fields_name() :: :__uf__
      def unknown_fields_name() do
        :__uf__
      end

      @spec clear_unknown_fields(struct) :: struct
      def clear_unknown_fields(msg) do
        struct!(msg, [{unknown_fields_name(), []}])
      end
    )

    (
      @spec required_fields() :: []
      def required_fields() do
        []
      end
    )

    (
      @spec syntax() :: atom()
      def syntax() do
        :proto3
      end
    )

    [
      @spec(default(atom) :: {:ok, boolean | integer | String.t() | float} | {:error, atom}),
      def default(:x) do
        {:ok, 0.0}
      end,
      def default(:y) do
        {:ok, 0.0}
      end,
      def default(:z) do
        {:ok, 0.0}
      end,
      def default(_) do
        {:error, :no_such_field}
      end
    ]

    (
      @spec file_options() :: nil
      def file_options() do
        nil
      end
    )
  end
]

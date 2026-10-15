defmodule ConvergerWeb.Protocol.GroupMembership do
  @moduledoc """
  One connection's view of its agent group (`hello.group`, docs/protocol/v1.md
  section 10, ADR-0063 and ADR-0069).

  The members of the group `{channel_id, name}` are the processes of the `:pg`
  group of that name in the scope `ConvergerWeb.Protocol.AgentGroups`, on
  every node. The connection monitors the group (`:pg.monitor/2`), so it sees
  members join and leave as messages in its own mailbox.

  ## Who serves a conversation

  Each member has an **eligibility time** (`since`, microseconds since the
  epoch): the time it joined plus the settle delay (`group_settle_ms` of
  `config :converger, ConvergerWeb.Protocol`, default 1000). A member is
  eligible for a user turn committed at or after its `since`. The owner of a
  turn is, among the members eligible for it, the one with the highest
  `:erlang.phash2({conversation_id, pid})` (rendezvous hashing); when no member
  is eligible yet (a group that just started), every member counts.

  Because the eligibility time is published with the member (its `:pg`
  "since" group, `{:since, key, pid, since}`, joined before the group itself)
  and compared with the turn's own `inserted_at`, every member decides the
  owner of a turn from the same numbers, whenever it processes the turn. A
  member joining therefore never takes a turn committed before it was
  eligible (that turn stays with its previous owner), and the settle delay
  gives `:pg` time to tell every node about it first.
  """

  @scope ConvergerWeb.Protocol.AgentGroups

  @enforce_keys [:key, :ref]
  defstruct [:key, :ref, members: %{}]

  @type t :: %__MODULE__{
          key: {binary(), binary()},
          ref: reference(),
          members: %{pid() => integer()}
        }

  @doc """
  Join the group `name` of `channel_id` and start monitoring it.

  Options: `:since` (the eligibility time, default now plus the settle delay).
  """
  @spec join(binary(), binary(), keyword()) :: t()
  def join(channel_id, name, opts \\ []) do
    key = {channel_id, name}
    since = Keyword.get_lazy(opts, :since, fn -> now() + settle_us() end)

    # The since group first: a member that sees this process in the group can
    # look its eligibility time up (the scope processes joins in order).
    :ok = :pg.join(@scope, since_group(key, self(), since), self())
    :ok = :pg.join(@scope, key, self())
    {ref, pids} = :pg.monitor(@scope, key)

    %__MODULE__{key: key, ref: ref, members: lookup(key, pids)}
  end

  @doc "Leave the group (also done by `:pg` when the process exits)."
  @spec leave(t()) :: :ok
  def leave(%__MODULE__{key: key, ref: ref} = membership) do
    :pg.demonitor(@scope, ref)
    since = Map.get(membership.members, self())
    if since, do: :pg.leave(@scope, since_group(key, self(), since), self())
    :pg.leave(@scope, key, self())
    :ok
  end

  @doc """
  A `:pg` monitor message of this membership: `{:joined, pids, membership}`,
  `{:left, pids, membership}`, or `:ignore` for any other message.
  """
  @spec handle(t(), term()) :: {:joined | :left, [pid()], t()} | :ignore
  def handle(%__MODULE__{ref: ref, key: key} = membership, {ref, :join, key, pids}) do
    members = Map.merge(membership.members, lookup(key, pids))
    {:joined, pids, %{membership | members: members}}
  end

  def handle(%__MODULE__{ref: ref, key: key} = membership, {ref, :leave, key, pids}) do
    {:left, pids, %{membership | members: Map.drop(membership.members, pids)}}
  end

  def handle(_membership, _message), do: :ignore

  @doc """
  The member that serves a user turn of `conversation_id` committed at `at`
  (a `DateTime`, microseconds since the epoch, or `:now`).
  """
  @spec owner(t(), binary(), DateTime.t() | integer() | :now) :: pid()
  def owner(%__MODULE__{members: members}, conversation_id, at) do
    at = to_us(at)

    candidates =
      case for({pid, since} <- members, since <= at, do: pid) do
        [] -> Map.keys(members)
        eligible -> eligible
      end

    case candidates do
      [] -> self()
      pids -> Enum.max_by(pids, &:erlang.phash2({conversation_id, &1}))
    end
  end

  @doc "Whether this process serves `conversation_id` at `at` (see `owner/3`)."
  @spec serves?(t() | nil, binary(), DateTime.t() | integer() | :now) :: boolean()
  def serves?(nil, _conversation_id, _at), do: true

  def serves?(membership, conversation_id, at),
    do: owner(membership, conversation_id, at) == self()

  @doc "A `DateTime` (or `:now`) as microseconds since the epoch."
  @spec to_us(DateTime.t() | integer() | :now) :: integer()
  def to_us(:now), do: now()
  def to_us(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)
  def to_us(at) when is_integer(at), do: at

  defp since_group(key, pid, since), do: {:since, key, pid, since}

  # The eligibility times of `pids`, from their since groups. A member whose
  # since group is not visible (yet) is eligible after the settle delay.
  defp lookup(key, pids) do
    wanted = MapSet.new(pids)

    published =
      for {:since, ^key, pid, since} <- :pg.which_groups(@scope),
          MapSet.member?(wanted, pid),
          into: %{},
          do: {pid, since}

    fallback = now() + settle_us()
    Map.new(pids, fn pid -> {pid, Map.get(published, pid, fallback)} end)
  end

  defp settle_us, do: ConvergerWeb.Protocol.config(:group_settle_ms) * 1000

  defp now, do: System.os_time(:microsecond)
end

defmodule Livebook.Settings do
  @moduledoc false

  # Keeps all Livebook settings that are backed by storage.

  import Ecto.Changeset, only: [apply_action: 2]

  alias Livebook.FileSystem
  alias Livebook.Storage
  alias Livebook.Settings.EnvVar

  @typedoc """
  An id that is used for file system's manipulation, either insertion or removal.
  """
  @type file_system_id :: Livebook.Utils.id()

  @doc """
  Returns the current autosave path.
  """
  @spec autosave_path() :: String.t() | nil
  def autosave_path() do
    case Storage.fetch_key(:settings, "global", :autosave_path) do
      {:ok, value} -> value
      :error -> default_autosave_path()
    end
  end

  @doc """
  Returns the default autosave path.
  """
  @spec default_autosave_path() :: String.t()
  def default_autosave_path() do
    Path.join(Livebook.Config.data_path(), "autosaved")
  end

  @doc """
  Sets the current autosave path.
  """
  @spec set_autosave_path(String.t()) :: :ok
  def set_autosave_path(autosave_path) do
    Storage.insert(:settings, "global", autosave_path: autosave_path)
  end

  @doc """
  Restores the default autosave path.
  """
  @spec reset_autosave_path() :: :ok
  def reset_autosave_path() do
    Storage.delete_key(:settings, "global", :autosave_path)
  end

  @doc """
  Returns all known file systems.
  """
  @spec file_systems() :: list(FileSystem.t())
  def file_systems() do
    restored_file_systems =
      Storage.all(:filesystem)
      |> Enum.sort_by(&Map.get(&1, :order, System.os_time()))
      |> Enum.map(&storage_to_fs/1)

    [Livebook.Config.local_file_system() | restored_file_systems]
  end

  @doc """
  Saves a new file system to the configured ones.
  """
  @spec save_file_system(FileSystem.t()) :: :ok
  def save_file_system(%FileSystem.S3{} = file_system) do
    attributes =
      file_system
      |> FileSystem.S3.to_config()
      |> Map.to_list()

    attrs = [{:type, "s3"}, {:order, System.os_time()} | attributes]
    :ok = Storage.insert(:filesystem, file_system.id, attrs)
  end

  @doc """
  Removes the given file system from the configured ones.
  """
  @spec remove_file_system(file_system_id()) :: :ok
  def remove_file_system(file_system_id) do
    if default_file_system_id() == file_system_id do
      Livebook.Storage.delete_key(:settings, "global", :default_file_system_id)
    end

    Livebook.NotebookManager.remove_file_system(file_system_id)

    Livebook.Storage.delete(:filesystem, file_system_id)
  end

  defp storage_to_fs(%{type: "s3"} = config) do
    case FileSystem.S3.from_config(config) do
      {:ok, fs} -> fs
      {:error, message} -> raise ArgumentError, "invalid S3 file system: #{message}"
    end
  end

  @doc """
  Returns whether the update check is enabled.
  """
  @spec update_check_enabled?() :: boolean()
  def update_check_enabled?() do
    case Storage.fetch_key(:settings, "global", :update_check_enabled) do
      {:ok, value} -> value
      :error -> true
    end
  end

  @doc """
  Sets whether the update check is enabled.
  """
  @spec set_update_check_enabled(boolean()) :: :ok
  def set_update_check_enabled(enabled) do
    Storage.insert(:settings, "global", update_check_enabled: enabled)
  end

  @doc """
  Gets a list of environment variables from storage.
  """
  @spec fetch_env_vars() :: list(EnvVar.t())
  def fetch_env_vars do
    for fields <- Storage.all(:env_vars) do
      struct!(EnvVar, Map.delete(fields, :id))
    end
  end

  @doc """
  Gets one environment variable from storage.

  Raises `RuntimeError` if the environment variable does not exist.
  """
  @spec fetch_env_var!(String.t()) :: EnvVar.t()
  def fetch_env_var!(id) do
    fields = Storage.fetch!(:env_vars, id)
    struct!(EnvVar, Map.delete(fields, :id))
  end

  @doc """
  Checks if environment variable already exists.
  """
  @spec env_var_exists?(String.t()) :: boolean()
  def env_var_exists?(id) do
    Storage.fetch(:env_vars, id) != :error
  end

  @doc """
  Sets the given environment variable.

  With success, notifies interested processes about environment variable
  data change. Otherwise, it will return an error tuple with changeset.
  """
  @spec set_env_var(EnvVar.t(), map()) :: {:ok, EnvVar.t()} | {:error, Ecto.Changeset.t()}
  def set_env_var(%EnvVar{} = env_var \\ %EnvVar{}, attrs) do
    changeset = EnvVar.changeset(env_var, attrs)

    with {:ok, env_var} <- apply_action(changeset, :insert) do
      {:ok, save_env_var(env_var)}
    end
  end

  defp save_env_var(env_var) do
    attributes = env_var |> Map.from_struct() |> Map.to_list()
    :ok = Storage.insert(:env_vars, env_var.name, attributes)
    :ok = broadcast_env_vars_change({:env_var_set, env_var})
    env_var
  end

  @doc """
  Unsets an environment variable from given id.

  With success, notifies interested processes about environment variable
  deletion. Otherwise, it does nothing.
  """
  @spec unset_env_var(String.t()) :: :ok
  def unset_env_var(id) do
    if env_var_exists?(id) do
      env_var = fetch_env_var!(id)
      Storage.delete(:env_vars, id)
      broadcast_env_vars_change({:env_var_unset, env_var})
    end

    :ok
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking environment variable changes.
  """
  @spec change_env_var(EnvVar.t(), map()) :: Ecto.Changeset.t()
  def change_env_var(%EnvVar{} = env_var, attrs \\ %{}) do
    EnvVar.changeset(env_var, attrs)
  end

  @doc """
  Subscribes to updates in settings information.

  ## Messages

    * `{:env_var_set, env_var}`
    * `{:env_var_unset, env_var}`

  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe do
    Phoenix.PubSub.subscribe(Livebook.PubSub, "settings")
  end

  @doc """
  Unsubscribes from `subscribe/0`.
  """
  @spec unsubscribe() :: :ok
  def unsubscribe do
    Phoenix.PubSub.unsubscribe(Livebook.PubSub, "settings")
  end

  # Notifies interested processes about environment variables data change.
  #
  # Broadcasts given message under the `"settings"` topic.
  defp broadcast_env_vars_change(message) do
    Phoenix.PubSub.broadcast(Livebook.PubSub, "settings", message)
  end

  @doc """
  Sets default file system.
  """
  @spec set_default_file_system(file_system_id()) :: :ok
  def set_default_file_system(file_system_id) do
    Livebook.Storage.insert(:settings, "global", default_file_system_id: file_system_id)
  end

  @doc """
  Returns the default file system.
  """
  @spec default_file_system() :: Filesystem.t()
  def default_file_system() do
    case Livebook.Storage.fetch(:filesystem, default_file_system_id()) do
      {:ok, file} -> storage_to_fs(file)
      :error -> Livebook.Config.local_file_system()
    end
  end

  @doc """
  Returns the default file system id.
  """
  @spec default_file_system_id() :: file_system_id()
  def default_file_system_id() do
    case Livebook.Storage.fetch_key(:settings, "global", :default_file_system_id) do
      {:ok, default_file_system_id} -> default_file_system_id
      :error -> "local"
    end
  end

  @doc """
  Returns the home directory in the default file system.
  """
  @spec default_file_system_home() :: FileSystem.File.t()
  def default_file_system_home(), do: FileSystem.File.new(default_file_system())
end

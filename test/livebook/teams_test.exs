defmodule Livebook.TeamsTest do
  use Livebook.TeamsIntegrationCase, async: true

  alias Livebook.Teams

  describe "create_org/1" do
    test "returns the device flow data to confirm the org creation" do
      org = build(:org)

      assert {:ok,
              %{
                "device_code" => _device_code,
                "expires_in" => 300,
                "id" => _org_id,
                "user_code" => _user_code,
                "verification_uri" => _verification_uri
              }} = Teams.create_org(org, %{})
    end

    test "returns changeset errors when data is invalid" do
      org = build(:org)

      assert {:error, changeset} = Teams.create_org(org, %{name: nil})
      assert "can't be blank" in errors_on(changeset).name
    end
  end

  describe "get_org_request_completion_data/1" do
    test "returns the org data when it has been confirmed", %{node: node, user: user} do
      teams_key = Teams.Org.teams_key()
      key_hash = :crypto.hash(:sha256, teams_key)

      org_request = :erpc.call(node, Hub.Integration, :create_org_request, [[key_hash: key_hash]])
      org_request = :erpc.call(node, Hub.Integration, :confirm_org_request, [org_request, user])

      org =
        build(:org,
          id: org_request.id,
          name: org_request.name,
          teams_key: teams_key,
          user_code: org_request.user_code
        )

      %{
        org: %{id: id, name: name, keys: [%{id: org_key_id}]},
        user: %{id: user_id},
        sessions: [%{token: token}]
      } = org_request.user_org

      assert Teams.get_org_request_completion_data(org) ==
               {:ok,
                %{
                  "id" => id,
                  "name" => name,
                  "org_key_id" => org_key_id,
                  "session_token" => token,
                  "user_id" => user_id
                }}
    end

    test "returns the org request awaiting confirmation", %{node: node} do
      teams_key = Teams.Org.teams_key()
      key_hash = :crypto.hash(:sha256, teams_key)

      org_request = :erpc.call(node, Hub.Integration, :create_org_request, [[key_hash: key_hash]])

      org =
        build(:org,
          id: org_request.id,
          name: org_request.name,
          teams_key: teams_key,
          user_code: org_request.user_code
        )

      assert Teams.get_org_request_completion_data(org) == {:ok, :awaiting_confirmation}
    end

    test "returns error when org request doesn't exist" do
      org = build(:org, id: 0)
      assert {:transport_error, _embarrassing} = Teams.get_org_request_completion_data(org)
    end

    test "returns error when org request expired", %{node: node} do
      now = NaiveDateTime.truncate(NaiveDateTime.utc_now(), :second)
      expires_at = NaiveDateTime.add(now, -5000)
      teams_key = Teams.Org.teams_key()
      key_hash = :crypto.hash(:sha256, teams_key)

      org_request =
        :erpc.call(node, Hub.Integration, :create_org_request, [
          [expires_at: expires_at, key_hash: key_hash]
        ])

      org =
        build(:org,
          id: org_request.id,
          name: org_request.name,
          teams_key: teams_key,
          user_code: org_request.user_code
        )

      assert Teams.get_org_request_completion_data(org) == {:error, :expired}
    end
  end
end

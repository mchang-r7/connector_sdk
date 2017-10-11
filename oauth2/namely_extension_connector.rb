{
  title: "Namely extension",

  connection: {
    fields: [
      { name: "company", control_type: :subdomain, url: ".namely.com", optional: false,
        hint: "If your Namely URL is https://acme.namely.com then use acme as value." },
      { name: "client_id", label: "Client ID", control_type: :password, optional: false },
      { name: "client_secret", control_type: :password, optional: false }
    ],

    authorization: {
      type: "oauth2",

      authorization_url: lambda do |connection|
        params = {
          response_type: "code",
          client_id: connection["client_id"],
          redirect_uri: "https://www.workato.com/oauth/callback",
        }.to_param
        "https://#{connection["company"]}.namely.com/api/v1/oauth2/authorize?" + params
      end,

      acquire: lambda do |connection, auth_code|
        response = post("https://#{connection["company"]}.namely.com/api/v1/oauth2/token").
                     payload(
                       grant_type: "authorization_code",
                       client_id: connection["client_id"],
                       client_secret: connection["client_secret"],
                       code: auth_code
                     ).request_format_www_form_urlencoded
        [ response, nil, nil ]
      end,

      refresh_on: [401, 403],

      refresh: lambda do |connection, refresh_token|
        post("https://#{connection["company"]}.namely.com/api/v1/oauth2/token").
          payload(
            grant_type: "refresh_token",
            client_id: connection["client_id"],
            client_secret: connection["client_secret"],
            refresh_token: refresh_token,
            redirect_uri: "https://www.workato.com/oauth/callback"
          ).request_format_www_form_urlencoded
      end,

      apply: lambda do |connection, access_token|
        headers("Authorization": "Bearer #{access_token}")
      end
    }
  },

  object_definitions: {
    profile: {
      fields: ->(connection) {
        required_hints = {
          "user_status" => "One of 'active', 'inactive' or 'pending'. "\
                           "Must be 'pending' if onboarding session is enabled",
          "personal_email" => "Required if Namely profile user status is pending,"\
                              " or if onboarding session is enabled",
          "reports_to" => "ID of employee profile whom employee reports to",
          "job_title" => "ID of job title, or the name of the title as defined"\
                         " in your Namely instance"
        }
        object_types = ["salary","address"]
        object_properties = {
          "salary" => [
            { name: "id", hint: "If present, will find and update an existing salary" },
            { name: "yearly_amount" },
            { name: "rate", hint: "One of 'annually', 'weekly', 'biweekly'. "\
                                  "Refer to platform documentation for more examples" },
            { name: "currency_type", control_type: :select, pick_list: "currencies",
              toggle_hint: "Select from list",
              toggle_field: {
                name: "currency_type", type: :string, control_type: :text,
                label: "Currency type (Custom)", toggle_hint: "Use custom value",
                hint: "Must be a valid ISO currency code"
              } },
            { name: "date", label: "Start date", type: :date }
          ],
          "address" => [
            { name: "address1" },
            { name: "address2" },
            { name: "city" },
            { name: "country_id", label: "Country", control_type: :select, pick_list: "countries",
              toggle_hint: "Select from list",
              toggle_field: {
                name: "country_id", type: :string, control_type: :text,
                label: "Country (Custom)", toggle_hint: "Use custom value",
                hint: "Must be a valid 2-digit ISO country code"
              } },
            { name: "state_id", hint: "US state only" },
            { name: "zip" }
          ]
        }
        fields = get("https://#{connection["company"]}.namely.com/api/v1/profiles/fields")["fields"]
        special = fields.select { |f| object_types.include? f["type"] }.
                         map do |field|
                           {
                             name: field["name"].downcase,
                             label: field["label"].humanize,
                             optional: true,
                             type: :object,
                             properties: object_properties[field["type"]]
                           }
                         end
        regular = fields.select { |f| !object_types.include? f["type"] }.
                         map do |field|
                           {
                             name: field["name"].downcase,
                             label: field["label"].humanize,
                             optional: true,
                             hint: required_hints[field["name"]].present? ?
                                     required_hints[field["name"]] :
                                       ((field["valid_format_info"] != "generic text") ?
                                         field["valid_format_info"].humanize : "")
                           }
                         end
        special.concat(regular)
      }
    },

    event: {
      fields: ->() {
        [
          { name: "id", label: "ID" },
          { name: "href", label: "URL" },
          { name: "type" },
          { name: "time", type: :integer },
          { name: "utc_offset", label: "UTC offset", type: :integer },
          { name: "content" },
          { name: "html_content" },
          { name: "years_at_company", type: :integer },
          { name: "use_comments", label: "Use comments?", type: :boolean },
          { name: "can_comment", label: "Can comment?", type: :boolean },
          { name: "can_destroy", label: "Can destroy?", type: :boolean },
          { name: "links", type: :object, properties: [
            { name: "profile" },
            { name: "comments", type: :array, of: :string },
            { name: "file" },
            { name: "appreciations", type: :array, of: :string },
          ] },
          { name: "can_like", label: "Can like?", type: :boolean },
          { name: "likes_count", type: :integer },
          { name: "liked_by_current_profile", type: :boolean },
        ]
      }
    },

    comment: {
      fields: ->() {
        [
          { name: "id", label: "ID" },
          { name: "content" },
          { name: "html_content" },
          { name: "created_at", type: :integer },
          { name: "can_destroy", label: "Can destroy?", type: :boolean },
          { name: "links", type: :object, properties: [
            { name: "profile" },
          ] },
          { name: "utc_offset", label: "UTC offset", type: :boolean },
          { name: "likes_count", type: :integer },
          { name: "liked_by_current_profile", type: :boolean },
        ]
      }
    }
  },

  test: lambda do |connection|
    get("https://#{connection["company"]}.namely.com/api/v1/profiles/me")
  end,

  actions: {
    create_announcement: {
      description: 'Create <span class="provider">announcement</span> '\
                   'in <span class="provider">Namely</span>',
      subtitle: "Create announcement in Namely",

      input_fields: lambda do
        [
          { name: "content", label: "Announcement text", optional: false,
            hint: "Format in Markdown. Use syntax "\
                  "[full_name](/people/profile_id) to mention a profile" },
          { name: "is_appreciation", type: :boolean,
            label: "Is appreciation?", optional: true,
            hint: "If true, any @mentioned profile will be appreciated" },
          { name: "email_all", type: :boolean,
            label: "Email all employees?", optional: true },
          { name: "file_id", optional: true, hint: "File ID of previously uploaded file" }
        ]
      end,

      execute: lambda do |connection, input|
        announcement = post("https://#{connection["company"]}.namely.com/api/v1/events").
                        payload(events: [input])["events"].first
        { announcement: announcement }
      end,

      output_fields: lambda do |object_definitions|
        [
          { name: "announcement", type: :object, properties: object_definitions["event"] }
        ]
      end,

      sample_output: lambda do |connection|
        {
          "announcement":
            get("https://#{connection["company"]}.namely.com/api/v1/events.json?type=announcement").
              params(
                page: 1,
                per_page: 1
              )["events"]
        }
      end
    },

    create_event_comment: {
      description: 'Create <span class="provider">event comment</span> '\
                   'in <span class="provider">Namely</span>',
      subtitle: "Create event comment in Namely",

      input_fields: lambda do
        [
          { name: "event_id", label: "Event ID", optional: false },
          { name: "content", label: "Comment", optional: false,
            hint: "Format in Markdown. Use syntax "\
                  "[full_name](/people/profile_id) to mention a profile" }
        ]
      end,

      execute: lambda do |connection, input|
        comment = post("https://#{connection["company"]}.namely.com/api/v1/events/#{input["event_id"]}/comments").
                        payload(comments: [input["content"]])["comments"].first
        { comment: comment }
      end,

      output_fields: lambda do |object_definitions|
        [
          { name: "comment", type: :object, properties: object_definitions["comment"] }
        ]
      end,

      sample_output: lambda do |connection|
        {
          "comment":
            get("https://#{connection["company"]}.namely.com/api/v1/events.json").
              params(
                page: 1,
                per_page: 1
              )["events"]
        }
      end
    },

    like_event_by_id: {
      description: 'Like an <span class="provider">event</span> '\
                   'in <span class="provider">Namely</span>',
      subtitle: "Like an event in Namely",
      hint: "Like functionality must be enabled in your Namely instance",

      input_fields: lambda do
        [
          { name: "id", label: "Event ID", optional: false }
        ]
      end,

      execute: lambda do |connection, input|
        message = post("https://#{connection["company"]}.namely.com/api/v1/likes/event/#{input["id"]}")["message"]
      end,

      output_fields: lambda do
        [
          { name: "likes_count", type: :integer },
          { name: "liked_by_current_profile", type: :boolean }
        ]
      end
    },

    like_comment_by_id: {
      description: 'Like an event or announcement\'s <span class="provider">comment</span> '\
                   'in <span class="provider">Namely</span>',
      subtitle: "Like an event or announcement's comment in Namely",
      hint: "Like functionality must be enabled in your Namely instance",

      input_fields: lambda do
        [
          { name: "id", label: "Comment ID", optional: false }
        ]
      end,

      execute: lambda do |connection, input|
        message = post("https://#{connection["company"]}.namely.com/api/v1/likes/event_comment/#{input["id"]}")["message"]
      end,

      output_fields: lambda do
        [
          { name: "likes_count", type: :integer },
          { name: "liked_by_current_profile", type: :boolean }
        ]
      end
    },

    create_employee_profile: {
      description: 'Create <span class="provider">employee profile</span> '\
                   'in <span class="provider">Namely</span>',
      subtitle: "Create employee profile in Namely",

      input_fields: lambda do |object_definitions|
        object_definitions["profile"].
          required(
            "email",
            "first_name",
            "last_name",
            "user_status",
            "start_date"
          )
      end,

      execute: lambda do |connection, input|
        profile = post("https://#{connection["company"]}.namely.com/api/v1/profiles").
                    payload(
                      { profiles: input }
                    )["profiles"].first
        { profile: profile }
      end,

      output_fields: lambda do |object_definitions|
        [
          {
            name: "profile",
            type: :object,
            properties: object_definitions["profile"]
          }
        ]
      end,

      sample_output: lambda do |connection|
        {
          "profile":
            get("https://#{connection["company"]}.namely.com/api/v1/profiles.json").
              params(
                page: 1,
                per_page: 1
              )["profiles"]
        }
      end
    },

    update_employee_profile: {
      description: 'Update <span class="provider">employee profile</span> '\
                   'in <span class="provider">Namely</span>',
      subtitle: "Update employee profile in Namely",

      input_fields: lambda do |object_definitions|
        [
          { name: "profile_id", label: "Profile ID", optional: false },
          { name: "profile", optional: false, type: :object,
            properties: object_definitions["profile"] }
        ]
      end,

      execute: lambda do |connection, input|
        profile = put("https://#{connection["company"]}.namely.com/api/v1/profiles/#{input["profile_id"]}").
                    payload(
                      { profiles: input["profile"] }
                    )["profiles"].first
        { profile: profile }
      end,

      output_fields: lambda do |object_definitions|
        [
          {
            name: "profile",
            type: :object,
            properties: object_definitions["profile"]
          }
        ]
      end,

      sample_output: lambda do |connection|
        {
          "profile":
            get("https://#{connection["company"]}.namely.com/api/v1/profiles.json").
              params(
                page: 1,
                per_page: 1
              )["profiles"]
        }
      end
    },

    get_employee_profile_by_id: {
      description: 'Get <span class="provider">employee profile</span> '\
                   'by ID in <span class="provider">Namely</span>',
      subtitle: "Get employee profile by ID in Namely",

      input_fields: lambda do
        [
          { name: "id", optional: false }
        ]
      end,

      execute: lambda do |connection, input|
        get("https://#{connection["company"]}.namely.com/api/v1/profiles/#{input["id"]}")["profiles"].first
      end,

      output_fields: lambda do |object_definitions|
        object_definitions["profile"]
      end,

      sample_output: lambda do |connection|
        get("https://#{connection["company"]}.namely.com/api/v1/profiles.json").
                        params(
                          page: 1,
                          per_page: 1
                        )["profiles"].first
      end
    },

    search_employee_profiles: {
      description: 'Search <span class="provider">employee profiles</span> '\
                   'in <span class="provider">Namely</span>',
      subtitle: "Search employee profiles in Namely",
      hint: "Use the input fields to add filters to employee profile results. "\
            "Leave input fields blank to return all employee profiles.",

      input_fields: lambda do
        [
          { name: "first_name", optional: true, sticky: true },
          { name: "last_name", optional: true, sticky: true },
          { name: "email", label: "Company email", optional: true, sticky: true },
          { name: "personal_email", optional: true },
          { name: "job_title", optional: true,
            hint: "ID of job title, or the name of the title as defined in your Namely instance" },
          { name: "reports_to", optional: true,
            hint: "ID of employee profile whom employee reports to" },
          { name: "user_status", optional: true, control_type: :select,
            pick_list: "employee_status", toggle_hint: "Select from list",
            toggle_field: {
              name: "user_status", type: :string, control_type: :text,
              label: "User status (Custom)", toggle_hint: "Use custom value"
            }, hint: "Inactive user status also returns pending profiles" },
          { name: "start_date", type: :date, optional: true }
        ]
      end,

      execute: lambda do |connection, input|
        params = (input["first_name"].present? ? "&filter[first_name]=#{input["first_name"]}" : "") +
                 (input["last_name"].present? ? "&filter[last_name]=#{input["last_name"]}" : "") +
                 (input["email"].present? ? "&filter[email]=#{input["email"]}" : "") +
                 (input["personal_email"].present? ? "&filter[personal_email]=#{input["personal_email"]}" : "") +
                 (input["job_title"].present? ? "&filter[job_title]=#{input["job_title"]}" : "") +
                 (input["reports_to"].present? ? "&filter[reports_to]=#{input["reports_to"]}" : "") +
                 (input["user_status"].present? ? "&filter[user_status]=#{input["user_status"]}" : "")
        employees = []
        page = 1
        count = 1
        while count != 0
          response = get("https://#{connection["company"]}.namely.com/api/v1/profiles.json?" +
                    params, page: page, per_page: 50)
          count = response["meta"]["count"]
          employees.concat(response["profiles"])
          page = page + 1
        end
        employees = employees.to_a
        if input["start_date"].present?
          employees = employees.where("start_date" => input["start_date"].to_s)
        end
        { "profiles": employees }
      end,

      output_fields: lambda do |object_definitions|
        [
          { name: "profiles",
            type: :array,
            of: :object,
            properties: object_definitions["profile"]
          }
        ]
      end,

      sample_output: lambda do |connection|
        {
          "profiles": get("https://#{connection["company"]}.namely.com/api/v1/profiles.json").
                        params(
                          page: 1,
                          per_page: 1
                        )["profiles"]
        }
      end
    },
  },

  triggers: {},

  pick_lists: {
    countries: lambda do |connection|
      get("https://#{connection["company"]}.namely.com/api/v1/countries.json").
        dig("countries").
        map { |c| [c["name"], c["id"]]}
    end,

    currencies: lambda do |connection|
      get("https://#{connection["company"]}.namely.com/api/v1/currency_types.json").
        dig("currency_types").
        map { |c| [c["name"], c["iso"]]}
    end,

    employee_status: lambda do
      [
        ["Active", "active"],
        ["Inactive", "inactive"],
        ["Pending", "pending"]
      ]
    end,

    employee_status_without_inactive: lambda do
      [
        ["Active", "active"],
        ["Pending", "pending"]
      ]
    end,

    event_type: lambda do
      [
        ["Birthday", "birthday"],
        ["Announcement", "announcement"],
        ["Recent arrival", "recent_arrival"],
        ["Anniversary", "anniversary"],
        ["All", "all"]
      ]
    end
  }
}

{
  title: "Workato Developer APIs",

  connection: {
    fields: [ 
      {
        name: "workato_environments",
        label: "Workato environments",
        item_label: "Environment",
        list_mode: "static",
        list_mode_toggle: false,
        type: "array",
        of: "object",
        properties: [
          {
            name: "name",
            label: "Environment name",
            optional: false,
            control_type: "select",
            options: [
              %w[DEV DEV],
              %w[TEST TEST],
              %w[PROD PROD]
            ],
            hint: "Select each environment only once. Modify SDK code if additional environments are needed."
          },                      
          {
            name: "email",
            label: "Email address",
            optional: false,
            hint: "Email address to access Workato platform APIs."
          },
          {
            name: "api_key",
            label: "API key",
            control_type: "password",
            optional: false,
            hint: "You can find your API key in the <a href=\"https://www.workato.com/users/current/edit#api_key\" target=\"_blank\">settings page</a>."
          }         
        ]
      }
    ],
    
    authorization: {
      type: "custom_auth",
    },
    
    base_uri: lambda do |connection|
      "https://www.workato.com"
    end,
       
  },
  
  test: lambda do |connection|
    connection["workato_environments"].each do |env|
      get("/api/users/me")
      .headers(call("get_auth_headers", connection, "DEV"))      
    end
  end,
  
  object_definitions: {
    package_details: {
      fields: lambda do
        [
          {
            name: "workato_environment",
            label: "Workato environment"
          },
          {
            name: "package_id",
            label: "Package ID"
          },
          {
            name: "api_mode",
            label: "API Mode"
          },           
          {
            name: "content",
            label: "Package content"
          }           
        ]
      end
    }, # package_details.end    
  },
  
  actions: {
    build_download_package: {
      title: "Build and download package",
      subtitle: "Build and download manifest or a project",
      
      help: "Use this action to build and export a manifest or project from the DEV environment.",
      
      description: lambda do |input| 
        "Build and download <span class='provider'>package</span> from " \
        "Workato <span class='provider'>DEV</span>"
      end,

      input_fields: lambda do |object_definitions, connection, config_fields|
        [ 
          {
            name: "api_mode",
            label: "Workato APIs",
            control_type: "select",
            pick_list: "api_mode",
            optional: false
          },
          {
            name: "id",
            label: "ID",
            hint: "Source manifest or project/folder ID to build.",
            optional: false
          },
          {
            name: "description",
            label: "Description",
            hint: "Release description for documentation.",
            optional: true,
            ngIf: "input.api_mode == 'projects'",
          }
        ]
      end,      
      
      execute: lambda do |connection, input, eis, eos, continue|
     
        continue = {} unless continue.present?
        current_step = continue['current_step'] || 1
        max_steps = 10
        step_time = current_step * 10 # This helps us wait longer and longer as we increase in steps
        headers = call("get_auth_headers", connection, "DEV")

        projects = true
        if(input["api_mode"] == "rlcm")  
          projects = false
        end # api_mode_if.end        
        
        if current_step == 1 # First invocation
          # Projects API - https://docs.workato.com/workato-api/projects.html#build-a-project
          # RLCM API - https://docs.workato.com/workato-api/recipe-lifecycle-management.html#export-package-based-on-a-manifest
          build_endpoint = projects ? "/api/projects/f#{input["id"]}/build" : "/api/packages/export/#{input["id"]}"
          build_body = projects ? { description:input["description"].to_s } : ""

          response = post(build_endpoint)
          .headers(headers)
          .request_body(build_body)
          .after_error_response(/.*/) do |_, body, _, message|
            error("#{message}: #{body}") 
          end
          
          res_in_progress = projects ? (response["state"] == "pending") : (response["status"] == "in_progress")
          res_failed = projects ? (response["state"] == "failed") : (response["status"] == "failed")
          res_success = projects ? (response["state"] == "success") : (response["status"] == "completed")

          # If job is in_progress, reinvoke after wait time
          current_step = current_step + 1
          max_steps = 10
          step_time = current_step * 10
          if res_in_progress == true
            reinvoke_after(
              seconds: step_time, 
              continue: { 
                current_step: current_step + 1, 
                jobid: response['id']
              }
            )
          elsif res_failed
            err_msg = response["error"].blank? ? "Package build and download failed." : response["error"]
            error(err_msg)
          elsif res_success
            call("download_from_url", {
              "headers" => headers, 
              # Fix v2.1 "workato_environment" => input["workato_environment"],
              "workato_environment" => "DEV",
              "download_url" => response["download_url"],
              "package_id" => response["id"],
              "api_mode" => input["api_mode"]
            })
          end # first_response_if.end
        
        # Subsequent invocations
        elsif current_step <= max_steps                 
          # Projects API - https://docs.workato.com/workato-api/projects.html#get-a-project-build
          # RLCM API - https://docs.workato.com/workato-api/recipe-lifecycle-management.html#get-package-by-id
          status_endpoint = projects ? "/api/project_builds/#{continue["jobid"]}" : "/api/packages/#{continue["jobid"]}"

          response = get(status_endpoint)
          .headers(headers)
          .after_error_response(/.*/) do |_, body, _, message|
            error("#{message}: #{body}") 
          end
          
          res_in_progress = projects ? (response["state"] == "pending") : (response["status"] == "in_progress")
          res_failed = projects ? (response["state"] == "failed") : (response["status"] == "failed")
          res_success = projects ? (response["state"] == "success") : (response["status"] == "completed")
          
          if res_in_progress
              reinvoke_after(
                seconds: step_time, 
                continue: { 
                  current_step: current_step + 1, 
                  jobid: response['id']
                }
              )
          elsif res_failed
            err_msg = response["error"].blank? ? "Package build and download failed." : response["error"]
            error(err_msg)
          elsif res_success
            call("download_from_url", {
              "headers" => headers, 
              "workato_environment" => "DEV",
              "download_url" => response["download_url"],
              "package_id" => response["id"],
              "api_mode" => input["api_mode"]              
            })
          end # subsequent_response_if.end

        else
          error("Job took too long!")
          
        end # outer.if.end
        
      end, # execute.end
      
      output_fields: lambda do |object_definitions|
        object_definitions["package_details"]
      end # output_fields.end
      
    }, # build_download_package.end
    
    download_package: {
      title: "Download package",
      subtitle: "Download existing package from Workato",
      
      help: "Use this action to download an existing package from the DEV environment.",
      
      description: lambda do |input| 
        "Download <span class='provider'>package</span> from " \
        "Workato <span class='provider'>DEV</span>"
      end,
      
      input_fields: lambda do |object_definitions, connection, config_fields|
        [  
          {
            name: "api_mode",
            label: "Workato APIs",
            control_type: "select",
            pick_list: "api_mode",
            optional: false
          },         
          {
            name: "id",
            label: "ID",
            hint: "Package or build ID to export.",
            optional: false            
          }
        ]
      end, 
      
      execute: lambda do |connection, input, eis, eos, continue|
        headers = call("get_auth_headers", connection, "DEV")

        projects = true
        if(input["api_mode"] == "rlcm")  
          projects = false
        end # api_mode_if.end

        # Projects API - https://docs.workato.com/workato-api/projects.html#get-a-project-build
        # RLCM API - https://docs.workato.com/workato-api/recipe-lifecycle-management.html#get-package-by-id
        status_endpoint = projects ? "/api/project_builds/#{input["id"]}" : "/api/packages/#{input["id"]}"

        response = get(status_endpoint)
        .headers(headers)
        .after_error_response(/.*/) do |_, body, _, message|
          error("#{message}: #{body}") 
        end        

        call("download_from_url", {
          "headers" => headers, 
          "workato_environment" => "DEV",
          "download_url" => response["download_url"],
          "package_id" => response["id"],
          "api_mode" => input["api_mode"]              
        })
    
      end, # execute.end
      
      output_fields: lambda do |object_definitions|
        object_definitions["package_details"]
      end # output_fields.end      
      
    }, # download_package.end
    
    deploy_package: {
      title: "Deploy package",
      subtitle: "Deploy package to Workato environment",
      
      help: "Use this action import a package to the selected environment. This is an asynchronous request and uses Workato long action. Learn more <a href=\"https://docs.workato.com/workato-api/recipe-lifecycle-management.html#import-package-into-a-folder\" target=\"_blank\">here</a>.",
      
      description: lambda do |input| 
        "Deploy <span class='provider'>package</span> to " \
        "Workato <span class='provider'>#{input["workato_environment"]}</span>"
      end,

      input_fields: lambda do |object_definitions, connection, config_fields|
        mode = config_fields['api_mode']       
        [
          {
            name: "api_mode",
            label: "Workato APIs",
            control_type: "select",
            pick_list: "api_mode",
            optional: false
          },          
          {
            name: "id",
            label: "ID",
            hint: "Package or build ID to deploy.",
            optional: false
          },
          {
            label: "Workato environment",
            type: "string",
            name: "workato_environment",
            ngIf: "input.api_mode == 'rlcm'",
            control_type: "select",
            toggle_hint: "Select from list",
            pick_list: "environments",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: "string",
              control_type: "text",
              optional: true,
              toggle_hint: "Custom value",
            },             
            optional: true,
            hint: "Select environment."
          },          
          {
            name: "folder_id",
            label: "Folder ID",
            hint: "Target environment folder ID to import package into.",
            ngIf: "input.api_mode == 'rlcm'",
            optional: true
          },                      
          {
            name: "env_type",
            label: "Environment type",
            hint: "Target environment type. Projects API currently supports only test and prod values.",
            control_type: "select",
            pick_list: "target_environment_types",
            ngIf: "input.api_mode == 'projects'",            
            optional: true
          },
          {
            name: "description",
            label: "Description",
            hint: "Deployment description for documentation.",
            optional: true,
            ngIf: "input.api_mode == 'projects'",
          }                                                 
        ]
      end,
      
      execute: lambda do |connection, input, eis, eos, continue|
        
        continue = {} unless continue.present?
        current_step = continue['current_step'] || 1
        max_steps = 10
        step_time = current_step * 10 # This helps us wait longer and longer as we increase in steps

        projects = true
        if(input["api_mode"] == "rlcm")  
          projects = false
        end # api_mode_if.end
        
        headers = projects ? call("get_auth_headers", connection, "DEV") : call("get_auth_headers", connection, "#{input["workato_environment"]}")
        
        if current_step == 1 # First invocation
          # Projects API - https://docs.workato.com/workato-api/projects.html#deploy-a-project-build
          # RLCM API - https://docs.workato.com/workato-api/recipe-lifecycle-management.html#export-package-based-on-a-manifest
          deploy_endpoint = projects ? "/api/project_builds/#{input["id"]}/deploy?environment_type=#{input["env_type"]}" : "/api/packages/import/#{input["folder_id"]}?restart_recipes=true"

          # For RLCM API, download package ID and use it for import
          deploy_body = ""
          if projects
            deploy_body = { "description" => input["description"].to_s }
            headers["Content-Type"] = "application/json"
          else
            # Existing package download should always happen from DEV, hence ensure src_env_headers irrespective of API mode
            src_env_headers = call("get_auth_headers", connection, "DEV")
            deploy_body = get("/api/packages/#{input["id"]}/download")
              .headers(headers).headers("Accept": "*/*")
              .after_error_response(/.*/) do |_code, body, _header, message|
                error("#{message}: #{body}")
              end.response_format_raw.encode('ASCII-8BIT')
            headers["Content-Type"] = "application/octet-stream"
          end

          response = post(deploy_endpoint) 
            .headers(headers)
            .request_body(deploy_body)
            .after_error_response(/.*/) do |_, body, _, message|
              error("#{message}: #{body}") 
            end

          res_in_progress = projects ? (response["state"] == "pending") : (response["status"] == "in_progress")
          res_failed = projects ? (response["state"] == "failed") : (response["status"] == "failed")
          res_success = projects ? (response["state"] == "success") : (response["status"] == "completed")          
          
          # If job is in_progress, reinvoke after wait time
          current_step = current_step + 1
          max_steps = 10
          step_time = current_step * 10 # This helps us wait longer and longer as we increase in steps
          if res_in_progress
              reinvoke_after(
                seconds: step_time, 
                continue: { 
                  current_step: current_step + 1, 
                  jobid: response['id']
                }
              )
          elsif res_failed
            err_msg = response["error"].blank? ? "Package build and download failed." : response["error"]
            error(err_msg)            
          elsif res_success
            {
              status: projects ? response["state"] : response["status"],
              job_id: response["id"]
            }
          end # first_response_if.end
          
        # Subsequent invocations
        elsif current_step <= max_steps           
          # Projects API - https://docs.workato.com/workato-api/projects.html#get-a-deployment
          # RLCM API - https://docs.workato.com/workato-api/recipe-lifecycle-management.html#get-package-by-id
          status_endpoint = projects ? "/api/deployments/#{continue["jobid"]}" : "/api/packages/#{continue["jobid"]}"

          response = get(status_endpoint)
          .headers(headers)
          .after_error_response(/.*/) do |_, body, _, message|
            error("#{message}: #{body}") 
          end

          res_in_progress = projects ? (response["state"] == "pending") : (response["status"] == "in_progress")
          res_failed = projects ? (response["state"] == "failed") : (response["status"] == "failed")
          res_success = projects ? (response["state"] == "success") : (response["status"] == "completed")               
          
          if res_in_progress
              reinvoke_after(
                seconds: step_time, 
                continue: { 
                  current_step: current_step + 1, 
                  jobid: response['id']
                }
              )
          elsif res_failed
            err_msg = response["error"].blank? ? "Package build and download failed." : response["error"]
            error(err_msg)
          elsif res_success
            {
              status: projects ? response["state"] : response["status"],
              job_id: response["id"]
            }
          end # subsequent_response_if.end

        else
          error("Job #{continue["jobid"]} took too long!")          
          
        end # outer.if.end
        
      end, # execute.end
      
      output_fields: lambda do |connection|
        [ 
          { name: "status" },
          { name: "job_id" },
        ]
      end
    }, # deploy_package.end
    
    list_folders: {
      title: "List folders",
      subtitle: "List folders in Workato environment",
      
      help: "Use this action list folders in the selected environment. Supports up to 100 folders lookup in single action. Repeat this action in recipe for pagination if more than 100 folders lookup is needed.",
      
      description: lambda do |input| 
        "List <span class='provider'>folders</span> in " \
        "<span class='provider'>Workato</span>"
      end,
      
      input_fields: lambda do |object_definitions| 
        [
          {
            label: "Workato environment",
            type: "string",
            name: "workato_environment",
            control_type: "select",
            toggle_hint: "Select from list",
            pick_list: "environments",
            toggle_field: {
              name: "workato_environment",
              label: "Workato environment",
              type: "string",
              control_type: "text",
              optional: false,
              toggle_hint: "Custom value",
            },             
            optional: false,
            hint: "Select environment."
          },
          {
            name: "page",
            hint: "Used for pagination.",
            type: "integer",
            default: 1
          }
        ]
      end, 
      
      execute: lambda do |connection, input, eis, eos, continue|
        page = input["page"] || 1
        headers = call("get_auth_headers", connection, "#{input["workato_environment"]}")
        { folders_list: get("/api/folders?page=#{page}&per_page=100")
        .headers(headers)
        .after_error_response(/.*/) do |_, body, _, message|
          error("#{message}: #{body}") 
        end }
        
      end, # execute.end
      
      output_fields: lambda do |object_definitions|
        [
          {
            name: "folders_list",
            label: "Folders list",
            control_type: "key_value",
            type: "array",
            of: "object",
            properties: [
              { name: "id" },
              { name: "name" },
              { name: "parent_id" },
              { name: "created_at" },
              { name: "updated_at" }            
            ]
          }
        ]
      end # output_fields.end      
      
    }, # list_folders.end    
    
  },
  
  methods: {
    get_auth_headers: lambda do |connection, env|
      auth_obj = connection["workato_environments"].select { |e| e["name"].include?("#{env}") }
      {
        "Authorization": "Bearer #{auth_obj[0]["api_key"]}"
      }
    end, # get_auth_headers.end
    
    download_from_url: lambda do |input|
      input["headers"][:Accept] = "*/*"
      { 
        workato_environment: input["workato_environment"],
        package_id: input["package_id"],
        api_mode: input["api_mode"],
        content: get(input["download_url"])
          .headers('Accept' => '*/*')
          .after_error_response(/.*/) do |_code, body, _header, message|
            error("#{message}: #{body}")
          end.response_format_raw
      }   
    end, # download_from_url.end
    
  },

  pick_lists: {
    api_mode: lambda do
      [
        %w[Projects projects],
        %w[Recipe\ Lifecycle\ Management rlcm]
      ]
    end,
    environments: lambda do |connection| 
      connection["workato_environments"].map do |env|
        ["#{env["name"]}", "#{env["name"]}"]
      end
    end,
    target_environment_types: lambda do
      [
        %w[Test test],
        %w[Production prod]
      ]
    end,    
  }
  
}
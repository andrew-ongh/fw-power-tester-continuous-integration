require 'sinatra'
require 'octokit'
require 'dotenv/load' # Manages environment variables
require 'json'
require 'openssl'     # Verifies the webhook signature
require 'jwt'         # Authenticates a GitHub App
require 'time'        # Gets ISO 8601 representation of a Time object
require 'logger'      # Logs debug statements
require 'git'
require 'httparty'
require 'open3'
require 'thread'
require 'date'
require 'aws-sdk-s3'
require 'fileutils'

set :port, 3000
set :bind, '0.0.0.0'

ABOVE_THIS_CURRENT_USAGE_THRESHOLD_IN_AMPS_FAILS_TEST = 0.008
MEASUREMENT_DURATION = 90
DIALOG_WORKSPACE = "/c/hh/dialog_14683_scratch"
# FileUtils.move() thinks /c/ is a folder instead of a drive letter 
DIALOG_WORKSPACE_WITH_ALT_DRIVE_LETTER = "C:/hh/dialog_14683_scratch" 

REPOSITORY_NAME = "dialog_14683_scratch"    #prevent running on other repositories 
MAX_RETRY_TIME_ELAPSED = 60 * 14  # wait 14 minutes maximum to download firmware after starting the check run 
    
# This is template code to create a GitHub App server.
# You can read more about GitHub Apps here: # https://developer.github.com/apps/
#
# On its own, this app does absolutely nothing, except that it can be installed.
# It's up to you to add functionality!
# You can check out one example in advanced_server.rb.
#
# This code is a Sinatra app, for two reasons:
#   1. Because the app will require a landing page for installation.
#   2. To easily handle webhook events.
#
# Of course, not all apps need to receive and process events!
# Feel free to rip out the event handling code if you don't need it.
#
# Have fun!
#

BOOTLOADER_UTILS_PATH="#{DIALOG_WORKSPACE}/utilities/scripts/qspi"
HPY_UTILS_PATH="#{DIALOG_WORKSPACE}/utilities/scripts/hpy/v11"

class GHAapp < Sinatra::Application

  # Expects that the private key in PEM format. Converts the newlines
  PRIVATE_KEY = OpenSSL::PKey::RSA.new(ENV['GITHUB_PRIVATE_KEY'].gsub('\n', "\n"))

  # Your registered app must have a secret set. The secret is used to verify
  # that webhooks are sent by GitHub.
  WEBHOOK_SECRET = ENV['GITHUB_WEBHOOK_SECRET']

  # The GitHub App's identifier (type integer) set when registering an app.
  APP_IDENTIFIER = ENV['GITHUB_APP_IDENTIFIER']

  semaphore = Mutex.new
  # For some reason, Github submits TWO check_run events per pull_request event, 
  # so work around the issue by refusing to measure the same commit twice in a row
  last_commit_hash = ""; 

  # Turn on Sinatra's verbose logging during development
  configure :development do
    set :logging, Logger::DEBUG
  end


  # Before each request to the `/event_handler` route
  before '/event_handler' do
    get_payload_request(request)
    verify_webhook_signature
    authenticate_app
    # Authenticate the app installation in order to run API operations
    authenticate_installation(@payload)
  end


  post '/event_handler' do

    # Get the event type from the HTTP_X_GITHUB_EVENT header
    case request.env['HTTP_X_GITHUB_EVENT']
    when 'check_run'
      # Check that the event is being sent to this app
      if @payload['check_run']['app']['id'].to_s === APP_IDENTIFIER
        a = Thread.new {
          semaphore.synchronize {
            case @payload['action']          
            when 'created'
              # For some reason, Github submits TWO check_run events per pull_request event, 
              # so work around the issue by refusing to measure the same commit twice in a row
              if last_commit_hash != commit_hash = @payload['check_run']['head_sha']
                initiate_check_run
                last_commit_hash = commit_hash = @payload['check_run']['head_sha']
              end
            when 'rerequested'
              create_check_run
            end
          }
        }
      end
    when 'check_suite'
      # A new check_suite has been created. Create a new check run with status queued
      if @payload['action'] == 'requested' || @payload['action'] == 'rerequested'
        create_check_run
      end
    when 'pull_request'
      if @payload['action'] == 'opened' || @payload['action'] == 'synchronize'
        create_check_run
      end
    end
  
    # # # # # # # # # # # #
    # ADD YOUR CODE HERE  #
    # # # # # # # # # # # #


    200 # success status
  end


  helpers do

    # # # # # # # # # # # # # # # # #
    # ADD YOUR HELPER METHODS HERE  #
    # # # # # # # # # # # # # # # # #
    # Start the CI process
    def initiate_check_run
      # Once the check run is created, you'll update the status of the check run
      # to 'in_progress' and run the CI process. When the CI finishes, you'll
      # update the check run status to 'completed' and add the CI results.

      if @payload['repository']['name'] != REPOSITORY_NAME
        return 
      end

      @installation_client.update_check_run(
        @payload['repository']['full_name'],
        @payload['check_run']['id'],
        status: 'queued',
        accept: 'application/vnd.github.v3+json'
      )


      result = download_firmware
      if result == "max_timeout_reached"
        # Mark the check run as timed out
        @installation_client.update_check_run(
          @payload['repository']['full_name'],
          @payload['check_run']['id'],
          status: 'completed',
          ## Conclusion: 
          #  Can be one of action_required, cancelled, failure, neutral, success, 
          #  skipped, stale, or timed_out. When the conclusion is action_required, 
          #  additional details should be provided on the site specified by details_url.
          conclusion: "timed_out", 
          output: {
            title: "Timed out. Did CirclCI Build successfully?",
            summary: "Firmware download did not finish after #{MAX_RETRY_TIME_ELAPSED}s. Did CircleCI build successfully?",
          },
          accept: 'application/vnd.github.v3+json'
        )
        return result
      elsif result == "job-failed-canceled"

        @installation_client.update_check_run(
          @payload['repository']['full_name'],
          @payload['check_run']['id'],
          status: 'completed',
          ## Conclusion: 
          #  Can be one of action_required, cancelled, failure, neutral, success, 
          #  skipped, stale, or timed_out. When the conclusion is action_required, 
          #  additional details should be provided on the site specified by details_url.
          conclusion: "cancelled", 
          output: {
            title: "No firmware to measure",
            summary: "CircleCI job failed/canceled. No firmware to measure.",
          },
          accept: 'application/vnd.github.v3+json'
        )
        return result 
      end

      ## QSPI erase is not supposed to be done for P8 or later because the unique 
      ## device information (e.g. serial number) is lost 
      ## 
      # erase_P8_qspi
      
      output = program_P8
      if output.include?("cannot open gdb interface") 
         # Mark the check run as failed
         @installation_client.update_check_run(
          @payload['repository']['full_name'],
          @payload['check_run']['id'],
          status: 'completed',
          ## Conclusion: 
          #  Can be one of action_required, cancelled, failure, neutral, success, 
          #  skipped, stale, or timed_out. When the conclusion is action_required, 
          #  additional details should be provided on the site specified by details_url.
          conclusion: "cancelled", 
          output: {
            title: "cannot open gdb interface. A cable is disconnected or the power is off",
            summary: "cannot open gdb interface. A cable is disconnected or the power is off. Did the RESET pin inverter light on fire?",
          },
          accept: 'application/vnd.github.v3+json'
        )

        return "program_P8_failed"
      elsif output.include?("done.") == false
        # Mark the check run as failed
        @installation_client.update_check_run(
          @payload['repository']['full_name'],
          @payload['check_run']['id'],
          status: 'completed',
          ## Conclusion: 
          #  Can be one of action_required, cancelled, failure, neutral, success, 
          #  skipped, stale, or timed_out. When the conclusion is action_required, 
          #  additional details should be provided on the site specified by details_url.
          conclusion: "cancelled", 
          output: {
            title: "unknown error",
            summary: "Unknown error. Details below",
            text: output
          },
          accept: 'application/vnd.github.v3+json'
        )

        return "program_P8_failed"
      end

      stdout, stderr, status = Open3.capture3("taskkill /f /im joulescope.exe")

      # Prevent duplicate files from taking up a lot of disk space 
      `rm -rf *.jls`
      `rm -rf *.png`

      # Turn on Joulescope and start measuring 
      result = joulescope_measurement

      if (result.downcase).include?("error")
        # Mark the check run as failed
        @installation_client.update_check_run(
          @payload['repository']['full_name'],
          @payload['check_run']['id'],
          status: 'completed',
          ## Conclusion: 
          #  Can be one of action_required, cancelled, failure, neutral, success, 
          #  skipped, stale, or timed_out. When the conclusion is action_required, 
          #  additional details should be provided on the site specified by details_url.
          conclusion: "cancelled", 
          output: {
            title: "Joulescope error",
            summary: "Joulescope error. Details below. Is Joulescope connected "\
            "and no application other than this script using it? Close Joulescope GUI.",
            text: result
          },
          accept: 'application/vnd.github.v3+json'
        )

        return "joulescope_measurement_failed"
      end
      
      
      date_time = (DateTime.now)
      date_time = date_time.new_offset('+00:00')
      image_file_name = date_time.strftime("%Y%m%d_%H%M%S.png")
      jls_file_name = `ls *.jls`
      jls_file_name = jls_file_name[0..-2] #remove the /r/n
      plot_first_few_seconds_file_name = date_time.strftime("%Y%m%d_%H%M%S_first_few_s.png")

      logger.debug "Taking Joulescope screenshot"
      # Open Joulescope window       
      pid = spawn("\"C:\\Program Files (x86)\\Joulescope\\joulescope.exe\" ./#{jls_file_name}")
      Process.detach(pid)
      sleep(10) # Wait for the Joulescope window to open and plot all data. Computer is slow. 
      # Use screen capture program 
      stdout, stderr, status = Open3.capture3("screenCapture.bat #{image_file_name} Joulescope:")
      output = stdout + stderr
      logger.debug output

      joulescope_output_parsed = eval(result)
      current_mean = joulescope_output_parsed[:"current_mean(A)"].to_f 
      if current_mean > ABOVE_THIS_CURRENT_USAGE_THRESHOLD_IN_AMPS_FAILS_TEST
        github_conclusion = "failure"
      else
        github_conclusion = "success"
      end

      # Make bar graph of the last few measurements
      commit_hash = @payload['check_run']['head_sha'][0..7]
      new_csv_line = date_time.strftime("%Y-%m-%d") + "," + commit_hash + "," + current_mean.to_s
      logger.debug "new_csv_line: " + new_csv_line
      stdout, stderr, status = Open3.capture3("python make_bar_chart.py #{plot_first_few_seconds_file_name} '#{new_csv_line}'")
      output = stdout + stderr
      logger.debug output
      
      # Upload files
      jls_URL = aws_s3_upload_file(jls_file_name)
      img_URL = aws_s3_upload_file(image_file_name)
      plot_first_few_s_URL = aws_s3_upload_file(plot_first_few_seconds_file_name)

      `taskkill /f /im joulescope.exe`
      
      full_repo_name = @payload['repository']['full_name']
      repository     = @payload['repository']['name']
      head_sha       = @payload['check_run']['head_sha']
      
      # Mark the check run as complete! And if there are warnings, share them.
      @installation_client.update_check_run(
        @payload['repository']['full_name'],
        @payload['check_run']['id'],
        status: 'completed',
        ## Conclusion: 
        #  Can be one of action_required, cancelled, failure, neutral, success, 
        #  skipped, stale, or timed_out. When the conclusion is action_required, 
        #  additional details should be provided on the site specified by details_url.
        conclusion: github_conclusion, 
        output: {
          title: "#{current_mean} A mean",
          summary: "P8 programmed and measured successfully. </p><a href=\"#{jls_URL}\">Download JLS file to see in Joulescope GUI (deleted after 7 days)</a></p><img src=\"#{img_URL}\"></p><img src=\"#{plot_first_few_s_URL}\">",
          text: result,
        },
        accept: 'application/vnd.github.v3+json'
      )
    end

    INITIAL_RETRY_TIME = 1

    #### Download the pre-built firmware from the blessed source: CircleCI ####
    def download_firmware
        retry_time_elapsed = INITIAL_RETRY_TIME
        begin
            # Get a list of CircleCI pipelines 

            begin 
                response = HTTParty.get('https://circleci.com/api/v2/pipeline?org-slug=gh/happy-health&mine=false', :headers => {"Circle-Token" => ENV['CIRCLE_CI_API_TOKEN']})
                    
                if response.code == 401 
                    raise "HTTP Response 401. Check CircleCI API key"  
                end
                if response.  code != 200
                    raise "HTTP Response #{response.code}"
                end
                rescue RuntimeError => e
                if retry_time_elapsed > MAX_RETRY_TIME_ELAPSED
                    logger.debug "Error: max timeout reached." 
                    return "max_timeout_reached"
                end 
                retry_time_elapsed = retry_time_elapsed * 2 # Exponential backoff 

                logger.debug "Error: #{e}, retrying in #{retry_time_elapsed} seconds..."
                response_parsed = JSON.parse(response)
                logger.debug response_parsed["message"]

                sleep(retry_time_elapsed)
                retry
            end

            response_parsed = JSON.parse(response)

            #    Expected response: 
            #
            #         {
            #   "next_page_token" : "AARLwwXBZCxa5TYj20yVNLUpMLKOqwfxyFwb48I7_RlgNOwE0hXEey64T1K9KwLn7MTxycgxKhEfnUO_pCYQcBjTHlnPcpBsW6mtbjQfeSVaxmUKTUzOhOQKlbSR2L3HX0-lRSoTyZx0tEmzLpaTidYiWGYMw8mB1zl_9vPeHv36_9qCWj8b1hY",
            #   "items" : [ {
            #     "id" : "d0bef5ec-c657-4d2c-bc18-76af58425804",
            #     "errors" : [ ],
            #     "project_slug" : "gh/happy-health/dialog_14683_scratch",
            #     "updated_at" : "2022-01-25T18:55:49.944Z",
            #     "number" : 2680,
            #     "state" : "created",
            #     "created_at" : "2022-01-25T18:55:49.944Z",
            #     "trigger" : {
            #       "received_at" : "2022-01-25T18:55:49.159Z",
            #       "type" : "webhook",
            #       "actor" : {
            #         "login" : "andrew-ongh",
            #         "avatar_url" : "https://avatars.githubusercontent.com/u/82856733?v=4"
            #       }
            #     },
            #     "vcs" : {
            #       "origin_repository_url" : "https://github.com/andrew-ongh/dialog_14683_scratch",
            #       "target_repository_url" : "https://github.com/happy-health/dialog_14683_scratch",
            #       "review_url" : "https://github.com/happy-health/dialog_14683_scratch/pull/594",
            #       "revision" : "3b15e384af8dcac939a4f5dbd55227d4d0107372",
            #       "review_id" : "594",
            #       "provider_name" : "GitHub",
            #       "commit" : {
            #         "body" : "",
            #         "subject" : "update readme"
            #       },
            #       "branch" : "pull/594"
            #     }
            
            matching_pipline = response_parsed["items"].select{|item| item["vcs"]["revision"] == @payload['check_run']['head_sha']}
            pipeline_id = matching_pipline[0]["id"]
            #author = matching_pipline[0]["trigger"]["actor"]["login"]
            #logger.debug "author: " + author

            #
            # Get a pipeline's workflows 
            #
            begin 
                response = HTTParty.get("https://circleci.com/api/v2/pipeline/#{pipeline_id}/workflow/", :headers => {"Circle-Token" => ENV['CIRCLE_CI_API_TOKEN']})
                    
                if response.code == 401 
                    raise "HTTP Response 401. Check CircleCI API key"  
                end
                if response.  code != 200
                    raise "HTTP Response #{response.code}"
                end
                rescue RuntimeError => e
                if retry_time_elapsed > MAX_RETRY_TIME_ELAPSED
                    logger.debug "Error: max timeout reached." 
                    return "max_timeout_reached"
                end 
                retry_time_elapsed = retry_time_elapsed * 2 # Exponential backoff 

                logger.debug "Error: #{e}, retrying in #{retry_time_elapsed} seconds..."
                response_parsed = JSON.parse(response)
                logger.debug response_parsed["message"]

                sleep(retry_time_elapsed)
                retry
            end

            response_parsed = JSON.parse(response)

            #    Expected response: 
            # 
            # {"next_page_token"=>nil,
            # "items"=>
            #  [{"pipeline_id"=>"45c684ea-ef37-43fb-871e-5380751f10f1",
            #    "id"=>"fd5638f7-a3eb-48df-b0e8-7dc45673e317",
            #    "name"=>"main",
            #    "project_slug"=>"gh/happy-health/dialog_14683_scratch",
            #    "status"=>"success",
            #    "started_by"=>"4ff88694-79d3-4303-87bf-a0d7c860c650",
            #    "pipeline_number"=>2687,
            #    "created_at"=>"2022-01-26T20:04:01Z",
            #    "stopped_at"=>"2022-01-26T21:20:11Z"}]}
          
            workflow_id = response_parsed["items"][0]["id"]

            #
            # Get workflow's jobs 
            #
            begin 
                response = HTTParty.get("https://circleci.com/api/v2/workflow/#{workflow_id}/job", :headers => {"Circle-Token" => ENV['CIRCLE_CI_API_TOKEN']})
                    
                if response.code == 401 
                    raise "HTTP Response 401. Check CircleCI API key"  
                end
                if response.  code != 200
                    raise "HTTP Response #{response.code}"
                end
                rescue RuntimeError => e
                if retry_time_elapsed > MAX_RETRY_TIME_ELAPSED
                    logger.debug "Error: max timeout reached." 
                    return "max_timeout_reached"
                end 
                retry_time_elapsed = retry_time_elapsed * 2 # Exponential backoff 

                logger.debug "Error: #{e}, retrying in #{retry_time_elapsed} seconds..."
                response_parsed = JSON.parse(response)
                logger.debug response_parsed["message"]

                sleep(retry_time_elapsed)
                retry
            end

            response_parsed = JSON.parse(response)

            #    Expected response: 
            # 
            # {"next_page_token"=>nil,
            #  "items"=>
            #   [{"dependencies"=>[],
            #     "job_number"=>27844,
            #     "id"=>"819ac62c-73cf-461a-a4b2-120fc5677069",
            #     "started_at"=>"2022-01-26T20:04:17Z",
            #     "name"=>"queue/block_workflow",
            #     "project_slug"=>"gh/happy-health/dialog_14683_scratch",
            #     "status"=>"success",
            #     "type"=>"build",
            #     "stopped_at"=>"2022-01-26T20:04:19Z"},
            #    {"dependencies"=>[],
            #     "job_number"=>27843,
            #     "id"=>"dcf731e0-99b3-42a1-9627-af12d7352d9d",
            #     "started_at"=>"2022-01-26T20:04:06Z",
            #     "name"=>"build_rf_tools_cli_p8_release",
            #     "project_slug"=>"gh/happy-health/dialog_14683_scratch",
            #     "status"=>"success",
            #     "type"=>"build",
            #     "stopped_at"=>"2022-01-26T21:17:30Z"},
            #    {"dependencies"=>[],
            #     "job_number"=>27839,
            #     "id"=>"2494fa7a-f452-4b92-b138-e2834456d2c4",
            #     "started_at"=>"2022-01-26T20:04:07Z",
            #     "name"=>"build_rf_tools_cli_p6_release",
            #     "project_slug"=>"gh/happy-health/dialog_14683_scratch",
            #     "status"=>"success",
            #     "type"=>"build",
            #     "stopped_at"=>"2022-01-26T21:17:39Z"},
            #    {"dependencies"=>[],
            #     "job_number"=>27840,
            #     "id"=>"2683e98d-0478-44e1-b295-0fece09305e8",
            #     "started_at"=>"2022-01-26T20:04:07Z",
            #     "name"=>"build_freertos_retarget_p8_release",
            #     "project_slug"=>"gh/happy-health/dialog_14683_scratch",
            #     "status"=>"success",
            #     "type"=>"build",

            matching_job = response_parsed["items"].select{|item| item["name"] == "pack_images"}
            job_number = matching_job[0]["job_number"]
            job_status = matching_job[0]["status"]
            
            if job_status == "failed" || job_status == "canceled" 
                # One of the CircleCI jobs was canclled or failed. 
                # Failed job = something did not build properly 
                # cancelled job = A newer commit in the same pull request was submitted before this job could finish 
                # (there are two different spellings for cancelled. CircleCI uses "canceled" and Github uses "cancelled")
                # in either case, this entire script should just stop for this Github commit 
                logger.debug "CircleCI job failed/canceled for commit " + @payload['check_run']['head_sha'] 
                return "job-failed-canceled"
            elsif job_status == [] 
                raise "CircleCI pack_images job not created yet. Commit " + @payload['check_run']['head_sha']
            else  
                # Check if job is finished yet 
                if job_status != "success"
                    raise "pack_images job status: " + job_status
                end
                # else job is a success 
                logger.debug 'CircleCI pack_images job found for commit ' + @payload['check_run']['head_sha']
            end
        rescue RuntimeError => e
            if retry_time_elapsed > MAX_RETRY_TIME_ELAPSED
            logger.debug "Error: max timeout reached." 
            return "max_timeout_reached"
            end 
            retry_time_elapsed = retry_time_elapsed * 2 # Exponential backoff 

            logger.debug "Error: #{e}, retrying in #{retry_time_elapsed} seconds..."
            
            response_parsed = JSON.parse(response)
            if(false == response_parsed["message"].nil?)
                logger.debug response_parsed["message"]
            end

            sleep(retry_time_elapsed)   
            retry 
        end      

        #
        # Fetch the CircleCI artifact URLs of this CircleCI job 
        #
        logger.debug "Fetching artifact URLs for job #{job_number}" 
        retry_time_elapsed = INITIAL_RETRY_TIME
        begin 
            response = HTTParty.get("https://circleci.com/api/v2/project/gh/happy-health/dialog_14683_scratch/#{job_number}/artifacts", :headers => {"Circle-Token" => ENV['CIRCLE_CI_API_TOKEN']})
            
            if response.code != 200
            raise "HTTP Response #{response.code}"
            end
        rescue RuntimeError => e
            if retry_time_elapsed > MAX_RETRY_TIME_ELAPSED
            logger.debug "Error: max timeout reached." 
            return "max_timeout_reached"
            end 
            retry_time_elapsed = retry_time_elapsed * 2 # Exponential backoff 

            logger.debug "Error: #{e}, retrying in #{retry_time_elapsed} seconds..."
            response_parsed = JSON.parse(response)
            logger.debug response_parsed["message"]

            sleep(retry_time_elapsed)   
            retry
        end
        # Filter the artifacts for only the P8 reelase 
        response_parsed = JSON.parse(response)

        # Expected response: 
        # 
        # {"next_page_token"=>nil,
        #  "items"=>
        #   [{"path"=>
        #      "~/builds/ble_suota_loader/DA14683-00-Release_QSPI/ble_suota_loader.bin",
        #     "node_index"=>0,
        #     "url"=>
        #      "https://27848-276286849-gh.circle-artifacts.com/0/%7E/builds/ble_suota_loader/DA14683-00-Release_QSPI/ble_suota_loader.bin"},
        #    {"path"=>
        #      "~/builds/ble_suota_loader/DA14683-00-Release_QSPI/ble_suota_loader.elf",
        #     "node_index"=>0,
        #     "url"=>
        #      "https://27848-276286849-gh.circle-artifacts.com/0/%7E/builds/ble_suota_loader/DA14683-00-Release_QSPI/ble_suota_loader.elf"},
        #    {"path"=>
        #      "~/builds/ble_suota_loader/DA14683-00-Release_QSPI/ble_suota_loader.map",
        #     "node_index"=>0,
        #     "url"=>
        #      "https://27848-276286849-gh.circle-artifacts.com/0/%7E/builds/ble_suota_loader/DA14683-00-Release_QSPI/ble_suota_loader.map"},
        #    {"path"=>
        #      "~/builds/ble_suota_loader/DA14683-00-Release_QSPI/ble_suota_loader_683_happy.bin.cached",
        #     "node_index"=>0,
        #     "url"=>
        #      "https://27848-276286849-gh.circle-artifacts.com/0/%7E/builds/ble_suota_loader/DA14683-00-Release_QSPI/ble_suota_loader_683_happy.bin.cached"},

        
        matching_artifact = response_parsed["items"].select{|item| item["path"] == "~/builds/freertos_retarget/Happy_P8_QSPI_Release/freertos_retarget.bin"}
        artifact_URL = matching_artifact[0]["url"]
        logger.debug "Firmware URL: " + artifact_URL

        # Download the firmware from the CircleCI artifact URL
        logger.debug "Downloading application firmware"
        begin 
            download_file(artifact_URL, "#{DIALOG_WORKSPACE_WITH_ALT_DRIVE_LETTER}/projects/dk_apps/templates/freertos_retarget/Happy_P8_QSPI_Release/freertos_retarget.bin")
        rescue RuntimeError => e
            if retry_time_elapsed > MAX_RETRY_TIME_ELAPSED
            logger.debug "Error: max timeout reached." 
            return "max_timeout_reached"
            end 
            retry_time_elapsed = retry_time_elapsed * 2 # Exponential backoff 

            logger.debug "Error: #{e}, retrying in #{retry_time_elapsed} seconds..."
            response_parsed = JSON.parse(response)
            logger.debug response_parsed["message"]

            sleep(retry_time_elapsed)   
            retry
        end

        # Filter the artifacts for only the bootloader
        
        matching_artifact = response_parsed["items"].select{|item| item["path"] == "~/builds/ble_suota_loader/DA14683-00-Release_QSPI/ble_suota_loader.bin"}
        artifact_URL = matching_artifact[0]["url"]
        logger.debug "Bootloader Firmware URL: " + artifact_URL

        # Download the firmware from the CircleCI artifact URL
        logger.debug "Downloading bootloader firmware"
        begin 
            download_file(artifact_URL, "#{DIALOG_WORKSPACE_WITH_ALT_DRIVE_LETTER}/sdk/bsp/system/loaders/ble_suota_loader/DA14683-00-Release_QSPI/ble_suota_loader.bin")
        rescue RuntimeError => e
            if retry_time_elapsed > MAX_RETRY_TIME_ELAPSED
            logger.debug "Error: max timeout reached." 
            return "max_timeout_reached"
            end 
            retry_time_elapsed = retry_time_elapsed * 2 # Exponential backoff 

            logger.debug "Error: #{e}, retrying in #{retry_time_elapsed} seconds..."
            response_parsed = JSON.parse(response)
            logger.debug response_parsed["message"]

            sleep(retry_time_elapsed)   
            retry
        end

    end 

    def download_file(url, destination_path)
      # download file without using the memory
      response = nil
      filename = (url.split('/', -1))[-1] # Get the end of the URL, e.g. "freertos_retarget.bin"

      File.open(filename, "w") do |file|
        response = HTTParty.get(url, :headers => {"Circle-Token" => ENV['CIRCLE_CI_API_TOKEN']},  stream_body: true) do |fragment|
          if [301, 302].include?(fragment.code)
            print "skip writing for redirect"
          elsif fragment.code == 200
            print "."
            file.write(fragment)
          else
            raise StandardError, "Non-success status code while streaming #{fragment.code}"
          end
        end
      end

      logger.debug "Filename: " + filename + " Destination: " + destination_path
    
      # If the folder does not exist then this will error. Pre-create the folder. 
      # Correct format for absolute path for this function: 
      #     "C:/hh/dialog_14683_scratch/sdk/bsp/system/loaders/ble_suota_loader/DA14683-00-Release_QSPI/ble_suota_loader.bin"
      FileUtils.mv(filename, destination_path)

      return "success"
    end

    def erase_P8_qspi
      logger.debug "Erasing QSPI"
      
      stdout, stderr, status = Open3.capture3("bash ./erase_qspi.sh")
      output = stdout + stderr
      logger.debug output
      return output
    end 

    def program_P8
      logger.debug "Flashing over JTAG"
      # Call script that flashes the firmware onto P8
      stdout, stderr, status = Open3.capture3("#{DIALOG_WORKSPACE_WITH_ALT_DRIVE_LETTER}\\utilities\\scripts\\hpy\\v11\\initial_flash.bat --jlink_path \"C:\\Program Files (x86)\\SEGGER\\JLink_V612i\"   \"#{DIALOG_WORKSPACE_WITH_ALT_DRIVE_LETTER}\\projects\\dk_apps\\templates\\freertos_retarget\\Happy_P8_QSPI_Release\\freertos_retarget.bin\"")
      output = stdout + stderr
      logger.debug output
      return output
    end 

    def joulescope_measurement
      logger.debug "Starting Joulescope measurement"
      stdout, stderr, status = Open3.capture3("python pyjoulescope/bin/trigger.py --start duration --start_duration 1  --end duration --capture_duration #{MEASUREMENT_DURATION} --display_stats --count 1 --init_power_off 3 --record")
      output = stdout + stderr
      logger.debug output
      return output
    end

    # Uploads an object to a bucket in Amazon Simple Storage Service (Amazon S3).
    #
    # Prerequisites:
    #
    # - An S3 bucket.
    # - An object to upload to the bucket.
    #
    # @param s3_client [Aws::S3::Client] An initialized S3 client.
    # @param bucket_name [String] The name of the bucket.
    # @param object_key [String] The name of the object.
    # @return [Boolean] true if the object was uploaded; otherwise, false.
    # @example
    #   exit 1 unless object_uploaded?(
    #     Aws::S3::Client.new(region: 'us-east-1'),
    #     'doc-example-bucket',
    #     'my-file.txt'
    #   )

    def aws_s3_object_uploaded?(s3_resource, bucket_name, object_key, file_path)
      object = s3_resource.bucket(bucket_name).object(object_key)
  
      if file_path.include?(".png")
        object.upload_file(file_path, {content_type: "image/png"})
      else
        object.upload_file(file_path)
      end
      
      return true
    rescue StandardError => e
      logger.debug "Error uploading object: #{e.message}"
      return false
    end
    
    # Full example call:
    def aws_s3_upload_file(filename)
      bucket_name = 'power-tester-artifacts'
      object_key = filename
      region = 'us-west-1'
      s3_client = Aws::S3::Resource.new(region: region,
        access_key_id: ENV['AWS_S3_API_KEY_ID'],
        secret_access_key: ENV['AWS_SECRET_ACCESS_KEY'])
    
      if aws_s3_object_uploaded?(s3_client, bucket_name, object_key, object_key)
        logger.debug "Object '#{object_key}' uploaded to bucket '#{bucket_name}'."
        return "https://" + bucket_name + ".s3." + region + ".amazonaws.com/" + object_key
      else
        logger.debug "Object '#{object_key}' not uploaded to bucket '#{bucket_name}'."
        return ""
      end
    end

    # Create a new check run with the status queued
    def create_check_run
      if @payload['repository']['name'] != REPOSITORY_NAME
        return 
      end

      # The payload structure differs depending on whether a check run or a check suite event occurred.
      if @payload['check_run'] != nil 
        commit_hash = @payload['check_run']['head_sha']
      elsif @payload['check_suite'] != nil
        commit_hash = @payload['check_suite']['head_sha']
      elsif @payload['pull_request'] != nil
        commit_hash = @payload['pull_request']['head']['sha']
      end

      @installation_client.create_check_run(
        # [String, Integer, Hash, Octokit Repository object] A GitHub repository.
        @payload['repository']['full_name'],
        # [String] The name of your check run.
        "P8 avg < #{ABOVE_THIS_CURRENT_USAGE_THRESHOLD_IN_AMPS_FAILS_TEST}A #{MEASUREMENT_DURATION}s after reset",
        # [String] The SHA of the commit to check 
        commit_hash, 
        # [Hash] 'Accept' header option, to avoid a warning about the API not being ready for production use.
        accept: 'application/vnd.github.v3+json'
      )
    end

    # Clones the repository to the current working directory, updates the
    # contents using Git pull, and checks out the ref.
    #
    # full_repo_name  - The owner and repo. Ex: octocat/hello-world
    # repository      - The repository name
    # ref             - The branch, commit SHA, or tag to check out
    def clone_repository(full_repo_name, repository, ref)
      @git = Git.clone("https://x-access-token:#{@installation_token.to_s}@github.com/#{full_repo_name}.git", repository)
      pwd = Dir.getwd()
      Dir.chdir(repository)
      @git.pull
      @git.checkout(ref)
      Dir.chdir(pwd)
    end

    # Saves the raw payload and converts the payload to JSON format
    def get_payload_request(request)
      # request.body is an IO or StringIO object
      # Rewind in case someone already read it
      request.body.rewind
      # The raw text of the body is required for webhook signature verification
      @payload_raw = request.body.read
      begin
        @payload = JSON.parse @payload_raw
      rescue => e
        fail  "Invalid JSON (#{e}): #{@payload_raw}"
      end
    end

    # Instantiate an Octokit client authenticated as a GitHub App.
    # GitHub App authentication requires that you construct a
    # JWT (https://jwt.io/introduction/) signed with the app's private key,
    # so GitHub can be sure that it came from the app an not altererd by
    # a malicious third party.
    def authenticate_app
      payload = {
          # The time that this JWT was issued, _i.e._ now.
          iat: Time.now.to_i,

          # JWT expiration time (10 minute maximum)
          exp: Time.now.to_i + (10 * 60),

          # Your GitHub App's identifier number
          iss: APP_IDENTIFIER
      }

      # Cryptographically sign the JWT.
      jwt = JWT.encode(payload, PRIVATE_KEY, 'RS256')

      # Create the Octokit client, using the JWT as the auth token.
      @app_client ||= Octokit::Client.new(bearer_token: jwt)
    end

    # Instantiate an Octokit client, authenticated as an installation of a
    # GitHub App, to run API operations.
    def authenticate_installation(payload)
      # @installation_id = payload['installation']['id']
      @installation_id = 18537730 # hardcoded since it doesn't come in the API for "pull_request" events
      @installation_token = @app_client.create_app_installation_access_token(@installation_id)[:token]
      @installation_client = Octokit::Client.new(bearer_token: @installation_token)
    end

    # Check X-Hub-Signature to confirm that this webhook was generated by
    # GitHub, and not a malicious third party.
    #
    # GitHub uses the WEBHOOK_SECRET, registered to the GitHub App, to
    # create the hash signature sent in the `X-HUB-Signature` header of each
    # webhook. This code computes the expected hash signature and compares it to
    # the signature sent in the `X-HUB-Signature` header. If they don't match,
    # this request is an attack, and you should reject it. GitHub uses the HMAC
    # hexdigest to compute the signature. The `X-HUB-Signature` looks something
    # like this: "sha1=123456".
    # See https://developer.github.com/webhooks/securing/ for details.
    def verify_webhook_signature
      their_signature_header = request.env['HTTP_X_HUB_SIGNATURE'] || 'sha1='
      method, their_digest = their_signature_header.split('=')
      our_digest = OpenSSL::HMAC.hexdigest(method, WEBHOOK_SECRET, @payload_raw)
      halt 401 unless their_digest == our_digest

      # The X-GITHUB-EVENT header provides the name of the event.
      # The action value indicates the which action triggered the event.
      logger.debug "---- received event #{request.env['HTTP_X_GITHUB_EVENT']}"
      logger.debug "----    action: #{@payload['action']}" unless @payload['action'].nil?
    end

  end

  # Finally some logic to let us run this server directly from the command line,
  # or with Rack. Don't worry too much about this code. But, for the curious:
  # $0 is the executed file
  # __FILE__ is the current file
  # If they are the same—that is, we are running this file directly, call the
  # Sinatra run method
  run! if __FILE__ == $0
end

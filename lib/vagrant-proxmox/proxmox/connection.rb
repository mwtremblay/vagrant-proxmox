require 'vagrant-proxmox/proxmox/errors'
require 'rest-client'
require 'retryable'

# Fix wrong header unescaping in RestClient library.
module RestClient
	class Request
		def make_headers user_headers
			unless @cookies.empty?
				user_headers[:cookie] = @cookies.map { |(key, val)| "#{key.to_s}=#{val}" }.sort.join('; ')
			end
			headers = stringify_headers(default_headers).merge(stringify_headers(user_headers))
			headers.merge!(@payload.headers) if @payload
			headers
		end
	end
end

module VagrantPlugins
	module Proxmox
		class Connection

			attr_reader :api_url
			attr_reader :ticket
			attr_reader :csrf_token
			attr_accessor :vm_id_range
			attr_accessor :task_timeout
			attr_accessor :task_status_check_interval
			attr_accessor :imgcopy_timeout

			def initialize api_url, opts = {}
				@api_url = api_url
				@vm_id_range = opts[:vm_id_range] || (900..999)
				@task_timeout = opts[:task_timeout] || 60
				@task_status_check_interval = opts[:task_status_check_interval] || 2
				@imgcopy_timeout = opts[:imgcopy_timeout] || 120
			end

			def login(username:, password:)
				begin
					response = post "/access/ticket", username: username, password: password
					@ticket = response[:data][:ticket]
					@csrf_token = response[:data][:CSRFPreventionToken]
				rescue ApiError::ServerError
					raise ApiError::InvalidCredentials
				rescue => x
					raise ApiError::ConnectionError, x.message
				end
			end

			def get_node_list
				nodelist = get '/nodes'
				nodelist[:data].map { |n| n[:node] }
			end

			def get_vm_state vm_id
				vm_info = get_vm_info vm_id
				if vm_info
					begin
						response = get "/nodes/#{vm_info[:node]}/#{vm_info[:type]}/#{vm_id}/status/current"
						states = {'running' => :running,
											'stopped' => :stopped}
						states[response[:data][:status]]
					rescue ApiError::ServerError
						:not_created
					end
				else
					:not_created
				end
			end

			def wait_for_completion task_response: task_response, timeout_message: timeout_message
				task_upid = task_response[:data]
				timeout = task_timeout
				task_type = /UPID:.*?:.*?:.*?:.*?:(.*)?:.*?:.*?:/.match(task_upid)[1]
				timeout = imgcopy_timeout if task_type == 'imgcopy'
				begin
					retryable(on: VagrantPlugins::Proxmox::ProxmoxTaskNotFinished,
										tries: timeout / task_status_check_interval + 1,
										sleep: task_status_check_interval) do
						exit_status = get_task_exitstatus task_upid
						exit_status.nil? ? raise(VagrantPlugins::Proxmox::ProxmoxTaskNotFinished) : exit_status
					end
				rescue VagrantPlugins::Proxmox::ProxmoxTaskNotFinished
					raise VagrantPlugins::Proxmox::Errors::Timeout.new timeout_message
				end
			end

			def delete_vm vm_id
				vm_info = get_vm_info vm_id
				response = delete "/nodes/#{vm_info[:node]}/#{vm_info[:type]}/#{vm_id}"
				wait_for_completion task_response: response, timeout_message: 'vagrant_proxmox.errors.destroy_vm_timeout'
			end

			def create_vm(node:, vm_type:, params:)
				response = post "/nodes/#{node}/#{vm_type}", params
				wait_for_completion task_response: response, timeout_message: 'vagrant_proxmox.errors.create_vm_timeout'
			end

			def start_vm vm_id
				vm_info = get_vm_info vm_id
				response = post "/nodes/#{vm_info[:node]}/#{vm_info[:type]}/#{vm_id}/status/start", nil
				wait_for_completion task_response: response, timeout_message: 'vagrant_proxmox.errors.start_vm_timeout'
			end

			def stop_vm vm_id
				vm_info = get_vm_info vm_id
				response = post "/nodes/#{vm_info[:node]}/#{vm_info[:type]}/#{vm_id}/status/stop", nil
				wait_for_completion task_response: response, timeout_message: 'vagrant_proxmox.errors.stop_vm_timeout'
			end

			def shutdown_vm vm_id
				vm_info = get_vm_info vm_id
				response = post "/nodes/#{vm_info[:node]}/#{vm_info[:type]}/#{vm_id}/status/shutdown", nil
				wait_for_completion task_response: response, timeout_message: 'vagrant_proxmox.errors.shutdown_vm_timeout'
			end

			def get_free_vm_id
				response = get "/cluster/resources?type=vm"
				allowed_vm_ids = vm_id_range.to_set
				used_vm_ids = response[:data].map { |vm| vm[:vmid] }
				free_vm_ids = (allowed_vm_ids - used_vm_ids).sort
				free_vm_ids.empty? ? raise(VagrantPlugins::Proxmox::Errors::NoVmIdAvailable) : free_vm_ids.first
			end

			def upload_file(file, content_type:, node:, storage:)
				unless is_file_in_storage? filename: file, node: node, storage: storage
					res = post "/nodes/#{node}/storage/#{storage}/upload", content: content_type,
										 filename: File.new(file, 'rb'), node: node, storage: storage
					wait_for_completion task_response: res, timeout_message: 'vagrant_proxmox.errors.upload_timeout'
				end
			end

			def list_storage_files(node:, storage:)
				res = get "/nodes/#{node}/storage/#{storage}/content"
				res[:data].map { |e| e[:volid] }
			end

			# This is called every time to retrieve the node and vm_type, hence on large
			# installations this could be a huge amount of data. Probably an optimization
			# with a buffer for the machine info could be considered.
			private
			def get_vm_info vm_id
				response = get '/cluster/resources?type=vm'
				response[:data]
				.select { |m| m[:id] =~ /^[a-z]*\/#{vm_id}$/ }
				.map {|m|	{id: vm_id, type: /^(.*)\/(.*)$/.match(m[:id])[1], node: m[:node]}}
				.first
			end

			private
			def get_task_exitstatus task_upid
				node = /UPID:(.*?):/.match(task_upid)[1]
				response = get "/nodes/#{node}/tasks/#{task_upid}/status"
				response[:data][:exitstatus]
			end

			private
			def get path
				begin
					response = RestClient.get "#{api_url}#{path}", {cookies: {PVEAuthCookie: ticket}}
					JSON.parse response.to_s, symbolize_names: true
				rescue RestClient::NotImplemented
					raise ApiError::NotImplemented
				rescue RestClient::InternalServerError
					raise ApiError::ServerError
				rescue RestClient::Unauthorized
					raise ApiError::UnauthorizedError
				rescue => x
					raise ApiError::ConnectionError, x.message
				end
			end

			private
			def delete path
				begin
					response = RestClient.delete "#{api_url}#{path}", headers
					JSON.parse response.to_s, symbolize_names: true
				rescue RestClient::Unauthorized
					raise ApiError::UnauthorizedError
				rescue RestClient::NotImplemented
					raise ApiError::NotImplemented
				rescue RestClient::InternalServerError
					raise ApiError::ServerError
				rescue => x
					raise ApiError::ConnectionError, x.message
				end
			end

			private
			def post path, params = {}
				begin
					response = RestClient.post "#{api_url}#{path}", params, headers
					JSON.parse response.to_s, symbolize_names: true
				rescue RestClient::Unauthorized
					raise ApiError::UnauthorizedError
				rescue RestClient::NotImplemented
					raise ApiError::NotImplemented
				rescue RestClient::InternalServerError
					raise ApiError::ServerError
				rescue => x
					raise ApiError::ConnectionError, x.message
				end
			end

			private
			def headers
				ticket.nil? ? {} : {CSRFPreventionToken: csrf_token, cookies: {PVEAuthCookie: ticket}}
			end

			private
			def is_file_in_storage?(filename:, node:, storage:)
				(list_storage_files node: node, storage: storage).find { |f| f =~ /#{File.basename filename}/ }
			end
		end
	end
end
#
# Copyright 2016, SUSE LINUX GmbH
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

require "open3"

module Api
  class Upgrade < Tableless
    class << self
      def status
        ::Crowbar::UpgradeStatus.new.progress
      end

      #
      # prechecks
      #
      def checks
        upgrade_status = ::Crowbar::UpgradeStatus.new
        # the check for current_step means to allow running the step at any point in time
        upgrade_status.start_step(:upgrade_prechecks)

        {}.tap do |ret|
          network = ::Crowbar::Sanity.check
          ret[:network_checks] = {
            required: true,
            passed: network.empty?,
            errors: network.empty? ? {} : sanity_check_errors(network)
          }

          maintenance_updates = ::Crowbar::Checks::Maintenance.updates_status
          ret[:maintenance_updates_installed] = {
            required: true,
            passed: maintenance_updates.empty?,
            errors: maintenance_updates.empty? ? {} : maintenance_updates_check_errors(
              maintenance_updates
            )
          }

          compute_resources = Api::Crowbar.compute_resources_status
          ret[:compute_resources_available] = {
            required: false,
            passed: compute_resources.empty?,
            errors: compute_resources.empty? ? {} : compute_resources_check_errors(
              compute_resources
            )
          }

          ceph_status = Api::Crowbar.ceph_status
          ret[:ceph_healthy] = {
            required: true,
            passed: ceph_status.empty?,
            errors: ceph_status.empty? ? {} : ceph_health_check_errors(ceph_status)
          } if Api::Crowbar.addons.include?("ceph")

          ha_presence = Api::Pacemaker.ha_presence_check
          ret[:ha_configured] = {
            required: false,
            passed: ha_presence.empty?,
            errors: ha_presence.empty? ? {} : ha_presence_errors(ha_presence)
          }

          clusters_health = Api::Pacemaker.health_report
          ret[:clusters_healthy] = {
            required: true,
            passed: clusters_health.empty?,
            errors: clusters_health.empty? ? {} : clusters_health_report_errors(clusters_health)
          } if Api::Crowbar.addons.include?("ha")

          return ret unless upgrade_status.current_step == :upgrade_prechecks

          errors = ret.select { |_k, v| v[:required] && v[:errors].any? }.map { |_k, v| v[:errors] }
          if errors.any?
            upgrade_status.end_step(false, prechecks: errors)
          else
            upgrade_status.end_step
          end
        end
      end

      def best_method
        checks_cached = checks
        return "none" if checks_cached.any? do |_id, c|
          c[:required] && !c[:passed]
        end
        return "non-disruptive" unless checks_cached.any? do |_id, c|
          (c[:required] || !c[:required]) && !c[:passed]
        end
        return "disruptive" unless checks_cached.any? do |_id, c|
          (c[:required] && !c[:passed]) && (!c[:required] && c[:passed])
        end
      end

      #
      # prepare upgrade
      #
      def prepare(options = {})
        ::Crowbar::UpgradeStatus.new.start_step(:upgrade_prepare)

        background = options.fetch(:background, false)

        if background
          prepare_nodes_for_crowbar_upgrade_background
        else
          prepare_nodes_for_crowbar_upgrade
        end
      end

      #
      # repocheck
      #
      def adminrepocheck
        upgrade_status = ::Crowbar::UpgradeStatus.new
        upgrade_status.start_step(:admin_repo_checks)
        # FIXME: once we start working on 7 to 8 upgrade we have to adapt the sles version
        zypper_stream = Hash.from_xml(
          `sudo /usr/bin/zypper-retry --xmlout products`
        )["stream"]

        {}.tap do |ret|
          if zypper_stream["message"] =~ /^System management is locked/
            return {
              status: :service_unavailable,
              error: I18n.t(
                "api.crowbar.zypper_locked", zypper_locked_message: zypper_stream["message"]
              )
            }
          end

          unless zypper_stream["prompt"].nil?
            return {
              status: :service_unavailable,
              error: I18n.t(
                "api.crowbar.zypper_prompt", zypper_prompt_text: zypper_stream["prompt"]["text"]
              )
            }
          end

          products = zypper_stream["product_list"]["product"]

          os_available = repo_version_available?(products, "SLES", "12.3")
          ret[:os] = {
            available: os_available,
            repos: {}
          }
          ret[:os][:repos][admin_architecture.to_sym] = {
            missing: ["SLES-12-SP3-Pool", "SLES12-SP3-Updates"]
          } unless os_available

          cloud_available = repo_version_available?(products, "suse-openstack-cloud", "8")
          ret[:openstack] = {
            available: cloud_available,
            repos: {}
          }
          ret[:openstack][:repos][admin_architecture.to_sym] = {
            missing: ["SUSE-OpenStack-Cloud-8-Pool", "SUSE-OpenStack-Cloud-8-Updates"]
          } unless cloud_available

          if ret.any? { |_k, v| !v[:available] }
            missing_repos = ret.collect do |k, v|
              next if v[:repos].empty?
              missing_repo_arch = v[:repos].keys.first.to_sym
              v[:repos][missing_repo_arch][:missing]
            end.flatten.compact.join(", ")
            upgrade_status.end_step(
              false,
              adminrepocheck: "Missing repositories: #{missing_repos}"
            )
          else
            upgrade_status.end_step
          end
        end
      end

      def noderepocheck
        upgrade_status = ::Crowbar::UpgradeStatus.new
        upgrade_status.start_step(:nodes_repo_checks)

        response = {}
        addons = Api::Crowbar.addons
        addons.push("os", "openstack").each do |addon|
          response.merge!(Api::Node.repocheck(addon: addon))
        end

        unavailable_repos = response.select { |_k, v| !v["available"] }
        if unavailable_repos.any?
          upgrade_status.end_step(
            false,
            nodes_repo_checks: "#{unavailable_repos.keys.join(", ")} repositories are missing"
          )
        else
          upgrade_status.end_step
        end
        response
      end

      def target_platform(options = {})
        platform_exception = options.fetch(:platform_exception, nil)

        case ENV["CROWBAR_VERSION"]
        when "4.0"
          if platform_exception == :ceph
            ::Crowbar::Product.ses_platform
          else
            ::Node.admin_node.target_platform
          end
        end
      end

      #
      # service shutdown
      #
      def services
        begin
          # prepare the scripts for various actions necessary for the upgrade
          service_object = CrowbarService.new(Rails.logger)
          service_object.prepare_nodes_for_os_upgrade
        rescue => e
          msg = e.message
          Rails.logger.error msg
          ::Crowbar::UpgradeStatus.new.end_step(false, nodes_services: msg)
        end

        # Initiate the services shutdown for all nodes
        errors = []
        upgrade_nodes = ::Node.find("state:crowbar_upgrade")
        cinder_node = nil
        upgrade_nodes.each do |node|
          if node.roles.include?("cinder-controller") &&
              (!node.roles.include?("pacemaker-cluster-member") || node["pacemaker"]["founder"])
            cinder_node = node
          end
          cmd = node.shutdown_services_before_upgrade
          next if cmd[0] == 200
          errors.push(cmd[1])
        end

        begin
          unless cinder_node.nil?
            cinder_node.wait_for_script_to_finish(
              "/usr/sbin/crowbar-delete-cinder-services-before-upgrade.sh", 300
            )
            save_upgrade_state("Deleting of cinder services was successful.")
          end
        rescue StandardError => e
          errors.push(
            e.message +
            "Check /var/log/crowbar/node-upgrade.log at #{cinder_node.name} "\
            "for details."
          )
        end

        if errors.any?
          ::Crowbar::UpgradeStatus.new.end_step(false, nodes_services: errors.join(","))
        else
          ::Crowbar::UpgradeStatus.new.end_step
        end
      end
      handle_asynchronously :services

      #
      # cancel upgrade
      #
      def cancel
        upgrade_status = ::Crowbar::UpgradeStatus.new
        unless upgrade_status.cancel_allowed?
          Rails.logger.error(
            "Not possible to cancel the upgrade at the step #{upgrade_status.current_step}"
          )
          raise ::Crowbar::Error::UpgradeCancelError.new(upgrade_status.current_step)
        end

        service_object = CrowbarService.new(Rails.logger)
        service_object.revert_nodes_from_crowbar_upgrade
        upgrade_status.initialize_state
      end

      #
      # nodes upgrade
      #
      def nodes
        status = ::Crowbar::UpgradeStatus.new

        remaining = status.progress[:remaining_nodes]
        substep = status.current_substep

        if remaining.nil?
          remaining = ::Node.find(
            "state:crowbar_upgrade AND NOT run_list_map:ceph_*"
          ).size
          ::Crowbar::UpgradeStatus.new.save_nodes(0, remaining)
        end

        if substep.nil? || substep.empty?
          substep = "controllers"
          ::Crowbar::UpgradeStatus.new.save_substep(substep)
        end

        if substep == "controllers"
          upgrade_controller_nodes
          substep = "computes"
          ::Crowbar::UpgradeStatus.new.save_substep(substep)
        end

        if substep == "computes"
          upgrade_all_compute_nodes
        end
        status.end_step
      rescue ::Crowbar::Error::UpgradeError => e
        ::Crowbar::UpgradeStatus.new.end_step(
          false,
          nodes_upgrade: e.message
        )
      rescue StandardError => e
        # end the step even for non-upgrade error, so we are not stuck with 'running'
        ::Crowbar::UpgradeStatus.new.end_step(
          false,
          nodes_upgrade: "Crowbar has failed. " \
            "Check /var/log/crowbar/production.log for details."
        )
        raise e
      end
      handle_asynchronously :nodes

      protected

      #
      # controller nodes upgrade
      #
      def upgrade_controller_nodes
        drbd_nodes = ::Node.find("drbd_rsc:*")
        return upgrade_drbd_clusters unless drbd_nodes.empty?

        founder = ::Node.find(
          "state:crowbar_upgrade AND pacemaker_founder:true"
        ).first
        cluster_env = founder[:pacemaker][:config][:environment]

        non_founder = ::Node.find(
          "state:crowbar_upgrade AND pacemaker_founder:false AND " \
          "pacemaker_config_environment:#{cluster_env}"
        ).first

        upgrade_first_cluster_node founder, non_founder

        # upgrade the rest of nodes in the same cluster
        ::Node.find(
          "state:crowbar_upgrade AND pacemaker_config_environment:#{cluster_env}"
        ).each do |node|
          upgrade_next_cluster_node node.name, founder.name
        end
      end

      # Method for upgrading first node of the cluster
      # other_node_name argument is the name of any other node in the same cluster
      def upgrade_first_cluster_node(node, other_node)
        node_api = Api::Node.new node.name
        return true if node_api.upgraded?
        other_node_api = Api::Node.new other_node.name
        node_api.save_node_state("controller")
        save_upgrade_state("Starting the upgrade of node #{node.name}")
        return false unless evacuate_network_node(node, node["hostname"])

        # upgrade the first node
        node_api.upgrade

        # Explicitly mark the first node as cluster founder
        # and in case of DRBD setup, adapt DRBD config accordingly.
        unless Api::Pacemaker.set_node_as_founder node.name
          raise_upgrade_error("Changing the cluster founder to #{node.name} has failed")
          return false
        end
        # remove pre-upgrade attribute, so the services can start
        other_node_api.disable_pre_upgrade_attribute_for node.name
        # delete old pacemaker resources (from the node where old pacemaker is running)
        delete_pacemaker_resources other_node.name
        # start crowbar-join at the first node
        node_api.post_upgrade
        node_api.join_and_chef
        node_api.save_node_state("controller", "upgraded")
      end

      def upgrade_next_cluster_node(node, founder)
        evacuate_network_node(founder, node["hostname"], true)
        node_api = Api::Node.new node.name
        return true if node_api.upgraded?
        node_api.save_node_state("controller")
        save_upgrade_state("Starting the upgrade of node #{node.name}")

        node_api.upgrade
        node_api.post_upgrade
        node_api.join_and_chef
        # Remove pre-upgrade attribute _after_ chef-client run because pacemaker is already running
        # and we want the configuration to be updated first
        # (disabling attribute causes starting the services on the node)
        node_api.disable_pre_upgrade_attribute_for node.name
        node_api.save_node_state("controller", "upgraded")
      end

      def upgrade_drbd_clusters
        ::Node.find(
          "state:crowbar_upgrade AND pacemaker_founder:true"
        ).each do |founder|
          cluster_env = founder[:pacemaker][:config][:environment]
          upgrade_drbd_cluster cluster_env
        end
      end

      def upgrade_drbd_cluster(cluster)
        save_upgrade_state("Upgrading controller nodes with DRBD-based storage " \
                           "in cluster \"#{cluster}\"")

        drbd_nodes = ::Node.find(
          "state:crowbar_upgrade AND "\
          "pacemaker_config_environment:#{cluster} AND " \
          "(roles:database-server OR roles:rabbitmq-server)"
        )
        if drbd_nodes.empty?
          save_upgrade_state("There's no DRBD-based node in cluster #{cluster}")
          return true
        end

        # First node to upgrade is DRBD slave. There might be more resources using DRBD backend
        # but the Master/Slave distribution might be different among them.
        # Therefore, we decide only by looking at the first DRBD resource we find in the cluster.
        drbd_slave = nil
        drbd_master = nil

        drbd_nodes.each do |drbd_node|
          cmd = "LANG=C crm resource status ms-drbd-{postgresql,rabbitmq}\
          | sort | head -n 2 | grep \\$(hostname) | grep -q Master"
          out = drbd_node.run_ssh_cmd(cmd)
          if out[:exit_code].zero?
            drbd_master = drbd_node
          else
            drbd_slave = drbd_node
          end
        end

        if drbd_slave.nil? || drbd_master.nil?
          raise_upgrade_error("Unable to detect drb master and/or slave nodes")
        end

        upgrade_first_cluster_node drbd_slave, drbd_master
        upgrade_next_cluster_node drbd_master, drbd_slave

        save_upgrade_state("Nodes in DRBD-based cluster successfully upgraded")
      end

      # Delete existing pacemaker resources, from other node in the cluster
      def delete_pacemaker_resources(node_name)
        node = ::Node.find_node_by_name node_name
        if node.nil?
          raise_upgrade_error(
            "Node #{node_name} was not found, cannot delete pacemaker resources."
          )
        end

        begin
          node.wait_for_script_to_finish(
            "/usr/sbin/crowbar-delete-pacemaker-resources.sh", 300
          )
          save_upgrade_state("Deleting pacemaker resources was successful.")
        rescue StandardError => e
          raise_upgrade_error(
            e.message +
            "Check /var/log/crowbar/node-upgrade.log for details."
          )
        end
      end

      # Evacuate all routers away from the specified network node to other
      # available network nodes. The evacuation procedure is started on the
      # specified controller node
      def evacuate_network_node(controller, network_node, delete_namespaces = false)
        args = [network_node]
        args << "delete-ns" if delete_namespaces
        controller.wait_for_script_to_finish(
          "/usr/sbin/crowbar-router-migration.sh", 600, args
        )
        save_upgrade_state("Migrating routers away from #{network_node} was successful.")

        # Cleanup up the ok/failed state files, as we likely need to
        # run the script again on this node (to evacuate other nodes)
        controller.delete_script_exit_files("/usr/sbin/crowbar-router-migration.sh")
      rescue StandardError => e
        raise_upgrade_error(
          e.message +
          " Check /var/log/crowbar/node-upgrade.log at #{controller.name} for details."
        )
      end

      #
      # compute nodes upgrade
      #
      def upgrade_all_compute_nodes
        ["kvm", "xen"].each do |virt|
          return false unless upgrade_compute_nodes virt
        end
        true
      end

      def upgrade_compute_nodes(virt)
        save_upgrade_state("Upgrading compute nodes of #{virt} type")
        compute_nodes = ::Node.find("roles:nova-compute-#{virt}")
        return true if compute_nodes.empty?

        controller = ::Node.find("roles:nova-controller").first
        if controller.nil?
          raise_upgrade_error("No nova controller node was found!")
          return false
        end

        # First batch of actions can be executed in parallel for all compute nodes
        begin
          execute_scripts_and_wait_for_finish(
            compute_nodes,
            "/usr/sbin/crowbar-prepare-repositories.sh",
            120
          )
          save_upgrade_state("Repositories prepared successfully.")
          execute_scripts_and_wait_for_finish(
            compute_nodes,
            "/usr/sbin/crowbar-pre-upgrade.sh",
            300
          )
          save_upgrade_state("Services at compute nodes upgraded and prepared.")
        rescue StandardError => e
          raise_upgrade_error(
            "Error while preparing services at compute nodes. " + e.message
          )
        end

        # Next part must be done sequentially, only one compute node can be upgraded at a time
        compute_nodes.each do |n|
          node_api = Api::Node.new n.name
          live_evacuate_compute_node(controller, n.name)
          node_api.os_upgrade
          node_api.reboot_and_wait
          node_api.post_upgrade
          node_api.join_and_chef

          out = controller.run_ssh_cmd(
            "source /root/.openrc; nova service-enable #{n.name} nova-compute"
          )
          unless out[:exit_code].zero?
            raise_upgrade_error(
              "Enabling nova-compute service for #{n.name} has failed!" \
              "Check nova log files at #{controller.name} and #{n.name}."
            )
          end
          save_upgrade_state("Node #{n.name} successfully upgraded.")
        end
        # FIXME: finalize compute nodes (move upgrade_step to done etc.)
        true
      end

      # Live migrate all instances of the specified
      # node to other available hosts.
      def live_evacuate_compute_node(controller, compute)
        controller.wait_for_script_to_finish(
          "/usr/sbin/crowbar-evacuate-host.sh", 300, [compute]
        )
        save_upgrade_state(
          "Migrating instances from node #{compute} was successful."
        )
      rescue StandardError => e
        raise_upgrade_error(
          e.message +
          "Check /var/log/crowbar/node-upgrade.log at #{controller.name} for details."
        )
      end

      def save_upgrade_state(message = "")
        # FIXME: update the global status
        Rails.logger.info(message)
      end

      def raise_upgrade_error(message = "")
        Rails.logger.error(message)
        raise ::Crowbar::Error::UpgradeError.new(message)
      end

      # Take a list of nodes and execute given script at each node in the background
      # Wait until all scripts at all nodes correctly finish or until some error is detected
      def execute_scripts_and_wait_for_finish(nodes, script, seconds)
        nodes.each do |node|
          ssh_status = node.ssh_cmd(script).first
          if ssh_status != 200
            raise_upgrade_error("Failed to connect to node #{node.name}!")
            raise "Execution of script #{script} has failed on node #{node.name}."
          end
        end

        scripts_status = {}
        begin
          Timeout.timeout(seconds) do
            nodes.each do |node|
              # wait until sript on this node finishes, than move to check next one
              loop do
                status = node.script_status(script)
                scripts_status[node.name] = status
                break if status != "running"
                sleep 1
              end
            end
          end
          failed = scripts_status.select { |_, v| v == "failed" }.keys
          unless failed.empty?
            raise "Execution of script #{script} has failed at node(s) " \
            "#{failed.join(",")}. " \
            "Check /var/log/crowbar/node-upgrade.log for details."
          end
        rescue Timeout::Error
          running = scripts_status.select { |_, v| v == "running" }.keys
          raise "Possible error during execution of #{script} at node(s) " \
            "#{running.join(",")}. " \
            "Action did not finish after #{seconds} seconds."
        end
      end

      #
      # prechecks helpers
      #
      # all of the below errors return a hash with the following schema:
      # code: {
      #   data: ... whatever data type ...,
      #   help: String # "this is how you might fix the error"
      # }
      def sanity_check_errors(check)
        {
          network_checks: {
            data: check,
            help: I18n.t("api.upgrade.prechecks.network_checks.help.default")
          }
        }
      end

      def maintenance_updates_check_errors(check)
        {
          maintenance_updates_installed: {
            data: check[:errors],
            help: I18n.t("api.upgrade.prechecks.maintenance_updates_check.help.default")
          }
        }
      end

      def ceph_health_check_errors(check)
        {
          ceph_health: {
            data: check[:errors],
            help: I18n.t("api.upgrade.prechecks.ceph_health_check.help.default")
          }
        }
      end

      def ha_presence_errors(check)
        {
          ha_configured: {
            data: check[:errors],
            help: I18n.t("api.upgrade.prechecks.ha_configured.help.default")
          }
        }
      end

      def clusters_health_report_errors(check)
        ret = {}
        crm_failures = check["crm_failures"]
        failed_actions = check["failed_actions"]
        ret[:clusters_health_crm_failures] = {
          data: crm_failures.values,
          help: I18n.t(
            "api.upgrade.prechecks.clusters_health.crm_failures",
            nodes: crm_failures.keys.join(",")
          )
        } if crm_failures
        ret[:clusters_health_failed_actions] = {
          data: failed_actions.values,
          help: I18n.t(
            "api.upgrade.prechecks.clusters_health.failed_actions",
            nodes: failed_actions.keys.join(",")
          )
        } if failed_actions
        ret
      end

      def compute_resources_check_errors(check)
        {
          compute_resources_available: {
            data: check[:errors],
            help: I18n.t("api.upgrade.prechecks.compute_resources_check.help.default")
          }
        }
      end

      #
      # prepare upgrade helpers
      #
      def prepare_nodes_for_crowbar_upgrade_background
        @thread = Thread.new do
          Rails.logger.debug("Started prepare in a background thread")
          prepare_nodes_for_crowbar_upgrade
        end

        @thread.alive?
      end

      def prepare_nodes_for_crowbar_upgrade
        service_object = CrowbarService.new(Rails.logger)
        service_object.prepare_nodes_for_crowbar_upgrade

        ::Crowbar::UpgradeStatus.new.end_step
        true
      rescue => e
        message = e.message
        ::Crowbar::UpgradeStatus.new.end_step(
          false,
          prepare_nodes_for_crowbar_upgrade: message
        )
        Rails.logger.error message

        false
      end

      #
      # repocheck helpers
      #
      def repo_version_available?(products, product, version)
        products.any? do |p|
          p["version"] == version && p["name"] == product
        end
      end

      def admin_architecture
        ::Node.admin_node.architecture
      end
    end
  end
end

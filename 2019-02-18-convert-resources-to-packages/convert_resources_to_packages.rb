#!/usr/bin/env ruby
# This script should be run after migration
# `20190211124513  Add cluster resource packages`. The migration creates
# personal resource packages for all users, so that every user has his own
# package with all the resources he has been assigned. The goal of this script
# is to replace the personal package with a set of standard packages, wherever
# we can be certain that the conversion makes sense.
# Resources that do not fit to any standard package are left in the personal
# package.
#
# Usage:
#   $0

Dir.chdir('/opt/vpsadmin/api')
require '/opt/vpsadmin/api/lib/vpsadmin'

# Necessary to load plugins
VpsAdmin::API.default

class Log
  def initialize(show_info: false)
    @show_info = show_info
  end

  def user(user)
    @user = user
    @print_user = false
    @level = 1

    yield

    puts if @print_user
  end

  def environment(env)
    @env = env
    @current = ''
    @error = false

    self << "Environment #{env.label}"
    @level += 1
    yield
    @level -= 1

    if @show_info || @error
      print_user
      puts @current
    end
  end

  def info(msg)
    self << msg
  end

  def error(msg)
    @error = true
    self << msg
  end

  protected
  def print_user
    unless @print_user
      puts "User #{@user.id} #{@user.login}"
      @print_user = true
    end
  end

  def <<(str)
    @current << ('  ' * @level) << str << "\n"
  end
end

class Convertor
  def self.run
    log = Log.new

    ActiveRecord::Base.transaction do
      ::User.where(object_state: [
        ::User.object_states[:active],
        ::User.object_states[:suspended],
        ::User.object_states[:soft_delete],
      ]).each do |user|
        log.user(user) do
          UserConvertor.run(log, user)
        end
      end

      fail 'nowai'
    end
  end
end

class UserConvertor
  def self.run(log, user)
    new(log, user).run
  end

  attr_reader :log, :user

  def initialize(log, user)
    @log = log
    @user = user
  end

  def run
    ::Environment.all.each do |env|
      c = EnvConvertor.get(env).new(log, user, env)
      c.run
    end
  end
end

class EnvConvertor
  MONTHLY_PAYMENT = 300

  class PackageAddError < StandardError ; end

  def self.get(env)
    case env.label
    when 'Production'
      ProductionConvertor
    when 'Playground'
      PlaygroundConvertor
    when 'Staging'
      StagingConvertor
    when 'Praha storage'
      StorageConvertor
    else
      fail "unsupported environment '#{env.label}'"
    end
  end

  attr_reader :log, :user, :env, :personal_pkg
  attr_accessor :recalculate

  def initialize(log, user, env)
    @log = log
    @user = user
    @env = env
    @personal_pkg = ::ClusterResourcePackage.where(user: user, environment: env).take!
  end

  def run
    log.environment(env) do
      convert
      user.calculate_cluster_resources_in_env(env) if recalculate
    end
  end

  def convert
    raise NotImplementedError
  end

  def add_pkg(pkg, generous: false)
    personal_items = Hash[personal_pkg.cluster_resource_package_items.map do |it|
      [it.cluster_resource_id, it]
    end]

    ucrp = ::UserClusterResourcePackage.create!(
      cluster_resource_package: pkg,
      environment: env,
      user: user,
      comment: 'Initial conversion from raw cluster resources.',
    )

    pkg.cluster_resource_package_items.each do |it|
      personal_item = personal_items[it.cluster_resource_id]

      if personal_item.nil?
        raise PackageAddError,
              "unable to add package #{pkg.label}: "+
              "resource #{it.cluster_resource.name} not found"
      elsif !generous && personal_item.value < it.value
        raise PackageAddError,
              "unable to add package #{pkg.label}: "+
              "not enough #{it.cluster_resource.name} in the personal package "+
              "(#{personal_item.value} < #{it.value})"
      end
    end

    pkg.cluster_resource_package_items.each do |it|
      personal_item = personal_items[it.cluster_resource_id]
      personal_item.value -= it.value
      personal_item.value = 0 if generous && personal_item.value < 0
      personal_item.save!
    end

    log.info("Added package #{pkg.id} #{pkg.label}")
  end

  def pkg_value(pkg, resource)
    pkg.cluster_resource_package_items.each do |it|
      return it.value if resource == it.cluster_resource.name.to_sym
    end

    0
  end

  def pkg_contains?(pkg, resources)
    return false if pkg_empty?(pkg)

    pkg.cluster_resource_package_items.where('value > 0').each do |it|
      r = it.cluster_resource.name.to_sym

      if resources.has_key?(r)
        if it.value < resources[r]
          return false
        else
          resources.delete(r)
        end
      end
    end

    resources.empty?
  end

  def pkg_empty?(pkg)
    pkg.cluster_resource_package_items.where('value > 0').empty?
  end

  def print_leftover(personal_pkg)
    personal_pkg.cluster_resource_package_items.where('value > 0').each do |it|
      log.error("#{it.cluster_resource.name}=#{it.value}")
    end
  end
end

class ProductionConvertor < EnvConvertor
  STD_PKG = ::ClusterResourcePackage.find_by!(label: 'Standard Production')
  EXT_PKG = ::ClusterResourcePackage.find_by!(label: 'Membership Expansion')
  IPV4_PKG =::ClusterResourcePackage.find_by!(label: 'Extra Public IPv4 Address')

  def convert
    # Everyone has the standard package
    begin
      add_pkg(STD_PKG)
    rescue PackageAddError
      log.error("unable to add pkg #{STD_PKG.label}")
      return
    end

    # Give private IPv4 freely
    private_ipv4 = pkg_value(personal_pkg, :ipv4_private)
    if private_ipv4 > 0
      (27..32).reverse_each do |prefix|
        cnt = 2 ** (32 - prefix)
        next if private_ipv4 > cnt

        add_pkg(::ClusterResourcePackage.find_by!(
          label: "Private IPv4 /#{prefix} (#{cnt} addresses)"
        ), generous: true)
        self.recalculate = true
        break
      end
    end

    if user.user_account.monthly_payment == 0
      # No membership fee, fuck it
      return

    elsif user.user_account.monthly_payment == MONTHLY_PAYMENT
      # Standard membership fee
      unless pkg_empty?(personal_pkg)
        # Has some extra resources
        log.error("has extra resources")
        print_leftover(personal_pkg)
      end
    else
      # Non-standard membership fee
      if (user.user_account.monthly_payment % MONTHLY_PAYMENT) == 0
        # Add membership expansions
        (user.user_account.monthly_payment / MONTHLY_PAYMENT).times do
          begin
            add_pkg(EXT_PKG)
          rescue PackageAddError
            break
          end

          add_pkg(IPV4_PKG) if pkg_contains?(personal_pkg, ipv4: 1)
        end

        unless pkg_empty?(personal_pkg)
          log.error("has extra resources")
          print_leftover(personal_pkg)
        end
      else
        # Something custom, fuck it
        log.error("has custom configuration, resources remaining:")
        print_leftover(personal_pkg)
      end
    end
  end
end

class PlaygroundConvertor < EnvConvertor
  STD_PKG = ::ClusterResourcePackage.find_by!(label: 'Standard Playground')
  EXT_PKG = ::ClusterResourcePackage.find_by!(label: 'Membership Expansion')

  def convert
    # Everyone has the standard package
    begin
      add_pkg(STD_PKG)
    rescue PackageAddError => e
      log.error("unable to add pkg #{STD_PKG.label}: #{e.message}")
      return
    end

    return if pkg_empty?(personal_pkg)

    # Non-standard membership fee
    if user.user_account.monthly_payment > MONTHLY_PAYMENT \
       && (user.user_account.monthly_payment % MONTHLY_PAYMENT) == 0
      # Add membership expansions
      (user.user_account.monthly_payment / MONTHLY_PAYMENT).times do
        begin
          add_pkg(EXT_PKG)
        rescue PackageAddError
          break
        end
      end

      unless pkg_empty?(personal_pkg)
        log.error("has extra resources")
        print_leftover(personal_pkg)
      end
    else
      # Something custom, fuck it
      log.error("has custom configuration, resources remaining:")
      print_leftover(personal_pkg)
    end
  end
end

class StagingConvertor < EnvConvertor
  STD_PKG = ::ClusterResourcePackage.find_by!(label: 'Standard Staging')

  def convert
    # Everyone has the standard package
    begin
      add_pkg(STD_PKG)
    rescue PackageAddError => e
      log.error("unable to add pkg #{STD_PKG.label}: #{e.message}")
      return
    end

    unless pkg_empty?(personal_pkg)
      log.error("has extra resources")
      print_leftover(personal_pkg)
    end
  end
end

class StorageConvertor < EnvConvertor
  STD_PKG = ::ClusterResourcePackage.find_by!(label: 'Standard NAS')
  
  def convert
    # Add NAS-only package
    begin
      add_pkg(STD_PKG)
    rescue PackageAddError => e
      log.error("unable to add pkg #{STD_PKG.label}: #{e.message}")
      return
    end

    unless pkg_empty?(personal_pkg)
      # Has some extra resources
      log.error("has extra resources")
      print_leftover(personal_pkg)
    end
  end
end

Convertor.run

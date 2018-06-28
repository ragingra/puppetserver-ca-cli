require 'optparse'
require 'openssl'
require 'puppetserver/ca/version'

# Option parser declares several default options that,
# unless overridden will raise a SystemExit. We delete
# version and help here as that behavior was breaking
# test driving those flags.
OptionParser::Officious.delete('version')
OptionParser::Officious.delete('help')

module Puppetserver
  module Ca
    class PuppetConfig

      attr_reader :errors, :ca_cert_path, :ca_key_path, :ca_crl_path
      def initialize(file_path_override = nil)
        @using_default_location = !file_path_override
        @config_path = file_path_override || user_specific_conf_file
        @results = {}
        @errors = []
      end

      def user_specific_conf_dir
        if Process::UID.eid == 0
          '/etc/puppetlabs/puppet'
        else
          "#{ENV['HOME']}/.puppetlabs/etc/puppet"
        end
      end

      def user_specific_conf_file
        user_specific_conf_dir + '/puppet.conf'
      end

      def load
        unless @using_default_location && !File.exist?(@config_path)
          @results = parse_text(File.read(@config_path))
        end

        @ca_cert_path, @ca_key_path, @ca_crl_path = resolve_settings(@results)
      end

      def resolve_settings(overrides)
        unresolved_setting = /\$[a-z_]+/
        master = overrides[:master] || {}
        main = overrides[:main] || {}
        pick = ->(key, default) { master[key] || main[key] || default }

        settings = Hash.new {|h, k| k }
        confdir = user_specific_conf_dir
        settings['$confdir'] = confdir

        ssldir = pick.call(:ssldir, '$confdir/ssl')
        settings['$ssldir'] = ssldir.sub('$confdir', confdir)

        cadir = pick.call(:cadir, '$ssldir/ca')
        settings['$cadir'] = cadir.sub(unresolved_setting, settings)

        cacert = pick.call(:cacert, '$cadir/ca_crt.pem')
        cakey = pick.call(:cakey, '$cadir/ca_key.pem')
        cacrl = pick.call(:cacrl, '$cadir/ca_crl.pem')

        values = [cacert, cakey, cacrl].map do |setting|
          setting.sub(unresolved_setting, settings)
        end

        values.each do |value|
          if value =~ unresolved_setting
            @errors << "Could not parse #{$1} in #{value}, " +
                       'valid settings to be interpolated are ' +
                       '$confdir, $ssldir, $cadir'
          end
        end

        return *values
      end

      def parse_text(text)
        res = {}
        current_section = :main
        text.each_line do |line|
          case line
          when /^\s*\[(\w+)\].*/
            current_section = $1.to_sym
          when /^\s*(\w+)\s*=\s*([^\s{#]+).*$/
            res[current_section] ||= {}
            res[current_section][$1.to_sym] = $2
          end
        end

        res
      end
    end

    class CAError < StandardError
      attr_reader :messages
      def initialize(*args)
        @messages = []
        super
      end

      def add_message(msg)
        @messages << msg
      end
    end

    class SetupCliParser
      def self.parse(cli_args, out, err)
        parser, inputs = parse_inputs(cli_args)
        exit_code = validate_inputs(inputs, parser.help, out, err)

        return inputs, exit_code
      end

      def self.validate_inputs(input, usage, out, err)
        exit_code = nil

        if input['help']
          out.puts usage
          exit_code = 0
        elsif input['version']
          out.puts Puppetserver::Ca::VERSION
          exit_code = 0
        elsif input['cert-bundle'].nil? || input['private-key'].nil?
          err.puts 'Error:'
          err.puts 'Missing required argument'
          err.puts '    Both --cert-bundle and --private-key are required'
          err.puts ''
          err.puts usage
          exit_code = 1
        end

        exit_code
      end

      def self.parse_inputs(inputs)
        parsed = {}

        parser = OptionParser.new do |opts|
          opts.banner = 'Usage: puppetserver ca setup [options]'
          opts.on('--help', 'This setup specific help output') do |help|
            parsed['help'] = true
          end
          opts.on('--version', 'Output the version') do |v|
            parsed['version'] = true
          end
          opts.on('--config CONF', 'Path to puppet.conf') do |conf|
            parsed['config'] = conf
          end
          opts.on('--private-key KEY', 'Path to PEM encoded key') do |key|
            parsed['private-key'] = key
          end
          opts.on('--cert-bundle BUNDLE', 'Path to PEM encoded bundle') do |bundle|
            parsed['cert-bundle'] = bundle
          end
          opts.on('--crl-chain [CHAIN]', 'Path to PEM encoded chain') do |chain|
            parsed['crl-chain'] = chain
          end
        end

        parser.parse(inputs)

        return parser, parsed
      end
    end

    class X509Loader

      attr_reader :errors, :certs, :key, :crls
      def initialize(bundle_file, key_file, chain_file)
        @bundle_file = bundle_file
        @key_file = key_file
        @chain_file = chain_file

        @certs, @key, @crls = nil, nil, nil

        @errors = []
      end

      def load_and_validate!
        @certs = parse_certs(@bundle_file)
        @key = parse_key(@key_file)

        @crls = @chain_file ? parse_crls(@chain_file) : []

        unless @crls.empty? || @certs.empty?
          validate_crl_and_cert(@crls.first, @certs.first)
        end

        if @key && !@certs.empty?
          validate_cert_and_key(@key, @certs.first)
        end

        unless @certs.empty?
          validate_full_chain(@certs, @crls)
        end
      end

      def parse_certs(bundle)
        errs = []
        errs << "Could not parse #{bundle}"

        bundle_string = File.read(bundle)
        cert_strings = bundle_string.scan(/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m)
        certs = cert_strings.map do |cert_string|
          begin
            OpenSSL::X509::Certificate.new(cert_string)
          rescue OpenSSL::X509::CertificateError
            errs << "Could not parse entry:\n#{cert_string}"

            nil
          end
        end.compact

        if certs.empty?
          errs << "Could not detect any certs within #{bundle}"
        end

        @errors += errs if errs.length > 1

        return certs
      end

      def parse_key(key_path)
        begin
          OpenSSL::PKey.read(File.read(key_path))
        rescue ArgumentError => e
          @errors << "Could not parse #{key_path}"

          return nil
        end
      end

      def parse_crls(chain)
        errs = []
        errs << "Could not parse #{chain}"

        chain_string = File.read(chain)
        crl_strings = chain_string.scan(/-----BEGIN X509 CRL-----.*?-----END X509 CRL-----/m)
        actual_crls = crl_strings.map do |crl_string|
          begin
            OpenSSL::X509::CRL.new(crl_string)
          rescue OpenSSL::X509::CRLError
            errs << "Could not parse entry:\n#{crl_string}"

            nil
          end
        end.compact

        if actual_crls.empty?
          errs << "Could not detect any crls within #{chain}"
        end

        @errors += errs if errs.length > 1

        return actual_crls
      end

      def validate_cert_and_key(key, cert)
        unless cert.check_private_key(key)
          @errors << 'Private key and certificate do not match'
        end
      end

      def validate_crl_and_cert(crl, cert)
        unless crl.issuer == cert.subject
          @errors << 'Leaf CRL was not issued by leaf certificate'
        end
      end

      def validate_full_chain(certs, crls)
        store = OpenSSL::X509::Store.new
        certs.each {|cert| store.add_cert(cert) }
        if crls
          store.flags = OpenSSL::X509::V_FLAG_CRL_CHECK | OpenSSL::X509::V_FLAG_CRL_CHECK_ALL
          crls.each {|crl| store.add_crl(crl) }
        end

        unless store.verify(certs.first)
          @errors << 'Leaf certificate could not be validated'
        end
      end
    end

    class Cli
      VALID_COMMANDS = ['setup']

      def self.run!(cli_args = ARGV, out = STDOUT, err = STDERR)

        if VALID_COMMANDS.include?(cli_args.first)
          case cli_args.shift
          when 'setup'
            input, exit_code = SetupCliParser.parse(cli_args, out, err)

            return exit_code if exit_code

            files = input.values_at('cert-bundle', 'private-key')
            files << input['crl-chain'] if input['crl-chain']
            files << input['config'] if input['config']

            errors = validate_file_paths(files)
            unless errors.empty?
              err.puts "Error:"
              errors.each do |message|
                err.puts "    #{message}"
              end
              return 1
            end

            unless input['crl-chain']
              err.puts 'Warning:'
              err.puts '    No CRL chain given'
              err.puts '    Full CRL chain checking will not be possible'
              err.puts ''
            end

            loader = X509Loader.new(input['cert-bundle'],
                                    input['private-key'],
                                    input['crl-chain'])

            loader.load_and_validate!

            unless loader.errors.empty?
              err.puts "Error:"
              loader.errors.each do |message|
                err.puts "    #{message}"
              end
              return 1
            end

            puppet = PuppetConfig.new(input['config'])
            puppet.load

            File.open(puppet.ca_cert_path, 'w') do |f|
              loader.certs.each do |cert|
                f.puts cert.to_pem
              end
            end

            File.open(puppet.ca_key_path, 'w') do |f|
              f.puts loader.key.to_pem
            end

            File.open(puppet.ca_crl_path, 'w') do |f|
              loader.crls.each do |crl|
                f.puts crl.to_pem
              end
            end

            return 0
          end
        else
          general_parser, input = parse_general_inputs(cli_args)

          if input['help']
            out.puts general_parser.help
          elsif input['version']
            out.puts Puppetserver::Ca::VERSION
          else
            err.puts general_parser.help
            return 1
          end
        end

        return 0
      end

      def self.validate_file_paths(one_or_more_paths)
        errors = []
        Array(one_or_more_paths).each do |path|
          if !File.exist?(path) || !File.readable?(path)
            errors << "Could not read file '#{path}'"
          end
        end

        errors
      end

      def self.parse_general_inputs(inputs)
        parsed = {}
        general_parser = OptionParser.new do |opts|
          opts.banner = 'Usage: puppetserver ca <command> [options]'
          opts.on('--help', 'This general help output') do |help|
            parsed['help'] = true
          end
          opts.on('--version', 'Output the version') do |v|
            parsed['version'] = true
          end
        end

        general_parser.parse(inputs)

        return general_parser, parsed
      end

    end
  end
end

require 'saml'
require 'corp_pass/providers/base'
require 'corp_pass/response'

module CorpPass
  module Providers
    class Actual < Base
      include CorpPass::Notification

      def sso_idp_initiated_url
        uri = URI(sso_url)
        params = sso_idp_initiated_url_params(uri)
        uri.query = URI.encode_www_form(params)
        notify(CorpPass::Events::SSO_IDP_INITIATED_URL, uri.to_s)
      end

      def slo_request_redirect(name_id)
        slo_request = make_sp_initiated_slo_request name_id, binding: :redirect
        [Saml::Bindings::HTTPRedirect.create_url(slo_request), slo_request]
      end

      def slo_response_redirect(logout_request)
        slo_response = make_idp_initiated_slo_response logout_request, binding: :redirect
        [Saml::Bindings::HTTPRedirect.create_url(slo_response), slo_response]
      end

      def artifact_resolution_url
        idp.artifact_resolution_service_url(configuration.artifact_resolution_service_url_index)
      end

      def parse_logout_response(request)
        message = Saml::Bindings::HTTPRedirect.receive_message(request, type: :logout_response)
        notify(CorpPass::Events::SLO_RESPONSE, message.to_xml)
        message
      end

      def parse_logout_request(request)
        message = Saml::Bindings::HTTPRedirect.receive_message(request, type: :logout_request)
        notify(CorpPass::Events::SLO_REQUEST, message.to_xml)
        message
      end

      def warden_strategy_name
        :corp_pass_actual
      end

      def warden_strategy
        CorpPass::Providers::ActualStrategy
      end

      private

      def sso_idp_initiated_url_params(uri)
        params = URI.decode_www_form(uri.query.nil? ? '' : uri.query)
        params.concat([
                        %w(RequestBinding HTTPArtifact),
                        %w(ResponseBinding HTTPArtifact),
                        ['PartnerId', configuration.sp_entity],
                        ['Target', configuration.sso_target],
                        %w(NameIdFormat Email),
                        ['esrvcId', configuration.eservice_id]
                      ])
        # params << %w(param1 NULL)
        # params << %w(param2 NULL)
        params
      end

      # Binding can be :redirect or :soap
      def make_sp_initiated_slo_request(name_id, binding: :redirect)
        destination = binding == :redirect ? slo_url_redirect : slo_url_soap
        slo_request = Saml::LogoutRequest.new destination: destination,
                                              name_id: name_id
        notify(CorpPass::Events::SLO_REQUEST, slo_request.to_xml)
        slo_request
      end

      def make_idp_initiated_slo_response(logout_request, binding: :redirect)
        destination = binding == :redirect ? slo_url_redirect : slo_url_soap
        slo_response = Saml::LogoutResponse.new destination: destination,
                                                in_response_to: logout_request._id,
                                                status_value: Saml::TopLevelCodes::SUCCESS
        notify(CorpPass::Events::SLO_RESPONSE, slo_response.to_xml)
        slo_response
      end

      def sso_url
        configuration.sso_idp_initiated_base_url
      end

      def slo_url_redirect
        idp.single_logout_service_url(Saml::ProtocolBinding::HTTP_REDIRECT)
      end

      def slo_url_soap
        idp.single_logout_service_url(Saml::ProtocolBinding::SOAP)
      end
    end

    class ArtifactResolutionFailure < CorpPass::Error
      attr_reader :xml
      def initialize(message, xml)
        super(message)
        @xml = xml
      end
    end

    class SamlResponseValidationFailure < CorpPass::Error
      attr_reader :xml
      attr_reader :messages
      def initialize(messages, xml)
        super(messages.join('; '))
        @messages = messages
        @xml = xml
      end
    end

    class ActualStrategy < BaseStrategy
      include CorpPass::Notification

      def artifact_resolution_url
        CorpPass.provider.artifact_resolution_url
      end

      def valid?
        notify(CorpPass::Events::STRATEGY_VALID,
               super && !warden.authenticated?(CorpPass::WARDEN_SCOPE) && !params['SAMLart'].blank?)
      end

      def authenticate!
        response = resolve_artifact!(request)
        user = response.cp_user
        notify(CorpPass::Events::AUTH_ACCESS, user.xml_document)
        begin
          user.validate!
        rescue CorpPass::InvalidUser => e
          notify(CorpPass::Events::INVALID_USER, "User XML validation failed: #{e}\nXML Received was:\n#{e.xml}")
          CorpPass::Util.throw_exception(e, CorpPass::WARDEN_SCOPE)
        end
        notify(CorpPass::Events::LOGIN_SUCCESS, "Logged in successfully #{user.user_id}")
        success! user
      end

      # You should expect an Artifact Resolution failure with no message for a successful connection
      def test_authentication!
        stub_request = Class.new do
          def params
            { 'SAMLart' => 'foobar' }
          end
        end

        message = catch(:warden) do
          resolve_artifact!(stub_request.new)
          'Successfully resolved artifact.'
        end

        if message.is_a?(Hash) && message[:type] == :exception
          exception = message[:exception]
          message = message.to_s
          message << "\nException: #{exception}"
          message << "\nXML: #{exception.xml}" if exception.respond_to?(:xml)
        end

        message.to_s
      end

      NETWORK_EXCEPTIONS = [::Timeout::Error, Errno::EINVAL, Errno::ECONNRESET, EOFError,
                            Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError, Net::ProtocolError].freeze

      # This method is concerned with rescuing from various exceptions thus, disabling AbcSize
      def resolve_artifact!(request, retrying_attempt = false) # rubocop:disable Metrics/AbcSize
        response = Saml::Bindings::HTTPArtifact.resolve(request, artifact_resolution_url, {}, proxy)
        check_response!(response)
      rescue *NETWORK_EXCEPTIONS => e
        if retrying_attempt
          notify(CorpPass::Events::NETWORK_ERROR, "Network error resolving artifact: #{e}")
          CorpPass::Util.throw_exception(e, CorpPass::WARDEN_SCOPE)
        else
          notify(CorpPass::Events::RETRY_AUTHENTICATION, "Retrying authentication due to #{e}")
          return resolve_artifact!(request, true)
        end
      rescue Saml::Errors::SamlError => e
        notify(CorpPass::Events::SAML_ERROR, "Saml Error: #{e.class.name} - #{e}")
        CorpPass::Util.throw_exception(e, CorpPass::WARDEN_SCOPE)
      rescue ArtifactResolutionFailure => e
        notify(CorpPass::Events::ARTIFACT_RESOLUTION_FAILURE, "Artifact resolution failure: #{e.xml}")
        CorpPass::Util.throw_exception(e, CorpPass::WARDEN_SCOPE)
      rescue SamlResponseValidationFailure => e
        notify(CorpPass::Events::SAML_RESPONSE_VALIDATION_FAILURE,
               "SamlResponse Validation failed failure: #{e.message} \n#{e.xml}")
        CorpPass::Util.throw_exception(e, CorpPass::WARDEN_SCOPE)
      end

      def check_response!(response)
        unless response.try(:success?)
          raise ArtifactResolutionFailure.new('Artifact resolution failed', # rubocop:disable Style/SignalException
                                              response.try(:to_xml))
        end
        response_xml = notify(CorpPass::Events::SAML_RESPONSE, response.to_xml)
        cp_response = CorpPass::Response.new(response)
        unless cp_response.valid?
          raise SamlResponseValidationFailure.new(cp_response.errors, # rubocop:disable Style/SignalException
                                                  response_xml)
        end
        cp_response
      end

      def proxy
        return {} if configuration.proxy_address.blank?
        {
          addr: configuration.proxy_address,
          port: configuration.proxy_port ? configuration.proxy_port.to_i : nil
        }
      end
    end
  end
end

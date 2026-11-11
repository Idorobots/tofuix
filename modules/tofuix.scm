;;; tofuix --- OpenTofu infrastructure in Guile Scheme

;;; Copyright © 2026 Kajetan Rzepecki
;;;
;;; This file is part of tofuix, released under the MIT license.

;;; The facade module: import (tofuix) to get the constructor macros, the
;;; programmatic record API, expressions, and the serializer.

(define-module (tofuix)
  #:use-module (tofuix records)
  #:use-module (tofuix expressions)
  #:use-module (tofuix serializer)
  #:re-export (configuration resource data provider variable output local
               obj

               tofu-configuration
               tofu-configuration?
               tofu-configuration-providers
               tofu-configuration-variables
               tofu-configuration-datas
               tofu-configuration-resources
               tofu-configuration-outputs
               tofu-configuration-locals
               tofu-configuration-root-blocks

               tofu-provider
               tofu-provider?
               tofu-provider-name
               tofu-provider-source
               tofu-provider-version
               tofu-provider-arguments

               tofu-resource
               tofu-resource?
               tofu-resource-type
               tofu-resource-name
               tofu-resource-arguments

               tofu-data
               tofu-data?
               tofu-data-type
               tofu-data-name
               tofu-data-arguments

               tofu-variable
               tofu-variable?
               tofu-variable-name
               tofu-variable-fields

               tofu-output
               tofu-output?
               tofu-output-name
               tofu-output-value
               tofu-output-fields

               tofu-local
               tofu-local?
               tofu-local-name
               tofu-local-value

               tofu-key->string
               tofu-merge-configuration-elements

               tofu-ref
               tofu-ref?
               tofu-ref-path
               tofu-ref->string
               attribute ref guile
               tf untf untf-splicing

               tofu-configuration->scm
               tofu-configuration->json))

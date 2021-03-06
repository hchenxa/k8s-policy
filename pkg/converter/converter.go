// Copyright (c) 2017 Tigera, Inc. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package converter

// Converter Responsible for conversion of given kubernetes object to equivalent calico object
type Converter interface {
	// Converts kubernetes object to calico representation of it.
	Convert(k8sObj interface{}) (interface{}, error)

	// Returns apporpriate key for the object
	GetKey(obj interface{}) string
}
